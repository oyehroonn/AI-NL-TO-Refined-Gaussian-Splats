#!/usr/bin/env python3
"""
Motion analyzer — Layer 3.

For every consecutive pair of kept frames, compute sparse Lucas-Kanade
optical flow, then decompose motion into:

  rotation_fraction   — how much of inter-frame motion is rotational
                        vs translational.  0 = pure translation,
                        1 = pure in-place rotation.
  translation_px      — median translation magnitude in pixels
  focus_of_expansion  — estimated FOE position (forward/backward motion)
  flow_angle          — dominant direction of camera movement (degrees 0-360)

Aggregate across all frame pairs to produce:
  - per-pair records (for NLP training fine-grain data)
  - summary statistics used by issue_classifier
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import NamedTuple

import cv2
import numpy as np


# ── Lucas-Kanade parameters ──────────────────────────────────────────────────
_LK_PARAMS = dict(
    winSize=(21, 21),
    maxLevel=3,
    criteria=(cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 30, 0.01),
)
_FEATURE_PARAMS = dict(
    maxCorners=200,
    qualityLevel=0.01,
    minDistance=8,
    blockSize=7,
)
_SMALL_W = 320  # downscale for speed


def _load_gray_small(path: Path) -> np.ndarray | None:
    img = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if img is None:
        return None
    h, w = img.shape
    if w > _SMALL_W:
        scale = _SMALL_W / w
        img = cv2.resize(img, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    return img


class FramePairMotion(NamedTuple):
    frame_a: str
    frame_b: str
    n_points: int               # number of tracked points
    rotation_angle_deg: float   # estimated rotation (affine decomposition)
    translation_px: float       # magnitude of translation vector (pixels at full res)
    rotation_fraction: float    # rotation / (rotation + translation), [0,1]
    flow_angle_deg: float       # dominant camera movement direction (0=right,90=up…)
    foe_x: float | None         # focus of expansion x (normalised -1..1, None if unclear)
    foe_y: float | None         # focus of expansion y (normalised -1..1, None if unclear)
    scale_factor: float         # ratio used when downscaling (for px→fullres conversion)


def _fit_affine_motion(
    pts_a: np.ndarray, pts_b: np.ndarray
) -> tuple[float, float, float]:
    """
    Fit 2D affine to flow vectors (pts_a → pts_b).

    Returns (rotation_deg, translation_px, rotation_fraction).
    Uses estimateAffinePartial2D (4-DOF: rotation + uniform scale + translation).
    """
    if len(pts_a) < 4:
        return 0.0, 0.0, 0.5

    M, inliers = cv2.estimateAffinePartial2D(
        pts_a.reshape(-1, 1, 2).astype(np.float32),
        pts_b.reshape(-1, 1, 2).astype(np.float32),
        method=cv2.RANSAC,
        ransacReprojThreshold=3.0,
    )
    if M is None:
        return 0.0, 0.0, 0.5

    # M = [[a, -b, tx], [b, a, ty]]
    # rotation angle = atan2(b, a)
    # scale = sqrt(a²+b²)
    a, b = float(M[0, 0]), float(M[1, 0])
    tx, ty = float(M[0, 2]), float(M[1, 2])

    rot_rad = math.atan2(b, a)
    rot_deg = abs(math.degrees(rot_rad))

    # Scale deviation from 1 indicates zoom/depth change
    scale = math.sqrt(a ** 2 + b ** 2)
    scale_deviation = abs(scale - 1.0)

    # "Rotational energy" proxy: arc length for a mid-image point moved by rotation
    # at radius = min(img_w, img_h)/4
    img_half_diag = 80.0  # ~quarter-diagonal of 320px wide image
    rot_arc_px = abs(rot_rad) * img_half_diag

    trans_px = math.sqrt(tx ** 2 + ty ** 2)

    total = rot_arc_px + trans_px
    rot_fraction = (rot_arc_px / total) if total > 1e-6 else 0.5

    return rot_deg, trans_px, rot_fraction


def _estimate_foe(
    pts_a: np.ndarray, pts_b: np.ndarray, img_w: int, img_h: int
) -> tuple[float | None, float | None]:
    """
    Estimate Focus of Expansion by finding where flow vectors converge.

    Returns (foe_x, foe_y) normalised to [-1,1] relative to image centre.
    Returns (None, None) if flow is too small or too noisy to estimate.
    """
    if len(pts_a) < 8:
        return None, None

    flow = pts_b - pts_a  # (N, 2)
    flow_mag = np.linalg.norm(flow, axis=1)
    if np.median(flow_mag) < 1.0:
        return None, None

    # For each flow vector (origin p, direction d), the FOE is the intersection
    # of lines. Least-squares estimate: minimise sum of squared distances from
    # lines.  Line through p=(px,py) in direction d=(dx,dy):
    #   dy*(X-px) - dx*(Y-py) = 0
    #   dy*X - dx*Y = dy*px - dx*py
    px = pts_a[:, 0].astype(np.float64)
    py = pts_a[:, 1].astype(np.float64)
    dx = flow[:, 0].astype(np.float64)
    dy = flow[:, 1].astype(np.float64)
    mag = np.sqrt(dx ** 2 + dy ** 2) + 1e-8
    dx /= mag
    dy /= mag

    # Build normal equations: A^T A x = A^T b
    # row: [dy, -dx], rhs: dy*px - dx*py
    a11 = np.sum(dy ** 2)
    a12 = -np.sum(dx * dy)
    a22 = np.sum(dx ** 2)
    b1 = np.sum(dy * (dy * px - dx * py))
    b2 = -np.sum(dx * (dy * px - dx * py))

    det = a11 * a22 - a12 ** 2
    if abs(det) < 1e-6:
        return None, None

    foe_px = (a22 * b1 - a12 * b2) / det
    foe_py = (-a12 * b1 + a11 * b2) / det

    # Normalise: 0 = image centre, ±1 = half-width/height from centre
    cx, cy = img_w / 2.0, img_h / 2.0
    foe_x = (foe_px - cx) / (img_w / 2.0)
    foe_y = (foe_py - cy) / (img_h / 2.0)

    return float(np.clip(foe_x, -5.0, 5.0)), float(np.clip(foe_y, -5.0, 5.0))


def analyze_motion_sequence(
    image_paths: list[Path],
    *,
    max_pairs: int = 120,
) -> dict:
    """
    Compute inter-frame motion for all consecutive pairs.

    Returns a rich dict with per-pair data and aggregate statistics.
    """
    paths = list(image_paths)
    if len(paths) < 2:
        return _empty_motion_result()

    # Subsample pairs if very many frames
    step = max(1, (len(paths) - 1) // max_pairs)
    pairs = [(paths[i], paths[i + step]) for i in range(0, len(paths) - step, step)]

    pair_records: list[dict] = []
    prev_gray: np.ndarray | None = None
    prev_path: Path | None = None

    for idx, (pa, pb) in enumerate(pairs):
        ga = _load_gray_small(pa)
        gb = _load_gray_small(pb)
        if ga is None or gb is None:
            continue

        h, w = ga.shape
        scale = w / max(cv2.imread(str(pa), cv2.IMREAD_GRAYSCALE).shape[1], 1)

        # Good features to track in frame A
        pts_a = cv2.goodFeaturesToTrack(ga, **_FEATURE_PARAMS)
        if pts_a is None or len(pts_a) < 8:
            continue

        # Track to frame B
        pts_b, status, _ = cv2.calcOpticalFlowPyrLK(ga, gb, pts_a, None, **_LK_PARAMS)
        if pts_b is None:
            continue

        mask = status.ravel() == 1
        if mask.sum() < 6:
            continue

        good_a = pts_a[mask].reshape(-1, 2)
        good_b = pts_b[mask].reshape(-1, 2)

        rot_deg, trans_px_small, rot_frac = _fit_affine_motion(good_a, good_b)
        # Scale translation back to full-res pixels
        trans_px_full = trans_px_small / max(scale, 1e-6)

        # Dominant flow direction (camera movement direction)
        flow_mean = (good_b - good_a).mean(axis=0)
        flow_angle = math.degrees(math.atan2(-float(flow_mean[1]), float(flow_mean[0]))) % 360

        foe_x, foe_y = _estimate_foe(good_a, good_b, w, h)

        pair_records.append(
            {
                "frame_a": pa.name,
                "frame_b": pb.name,
                "n_points": int(mask.sum()),
                "rotation_angle_deg": round(rot_deg, 3),
                "translation_px": round(trans_px_full, 2),
                "rotation_fraction": round(rot_frac, 3),
                "flow_angle_deg": round(flow_angle, 1),
                "foe_x": round(foe_x, 3) if foe_x is not None else None,
                "foe_y": round(foe_y, 3) if foe_y is not None else None,
            }
        )

    if not pair_records:
        return _empty_motion_result()

    return _aggregate_motion(pair_records)


def _aggregate_motion(pair_records: list[dict]) -> dict:
    rot_fracs = [r["rotation_fraction"] for r in pair_records]
    trans_pxs = [r["translation_px"] for r in pair_records]
    rot_degs = [r["rotation_angle_deg"] for r in pair_records]
    flow_angles = [r["flow_angle_deg"] for r in pair_records]

    # Rotation-in-place score: median rotation fraction
    median_rot_frac = float(np.median(rot_fracs))
    # High if > 0.65 (most motion is rotational)

    # Translation magnitude
    median_trans = float(np.median(trans_pxs))
    mean_trans = float(np.mean(trans_pxs))
    max_trans = float(np.max(trans_pxs))

    # Frames with very low translation (<4px at full res)
    static_pair_frac = float(np.mean([1 if t < 4.0 else 0 for t in trans_pxs]))

    # Direction diversity: bucket flow angles into 8 sectors (45° each)
    sector_counts = [0] * 8
    for ang in flow_angles:
        sector = int((ang + 22.5) % 360 / 45) % 8
        sector_counts[sector] = sector_counts[sector] + 1
    n_covered = sum(1 for c in sector_counts if c > 0)
    direction_diversity = n_covered / 8.0  # 1.0 = all 8 directions covered

    # Directionality: if most flow points the same way → one-directional capture
    angles_rad = [math.radians(a) for a in flow_angles]
    mean_cos = float(np.mean([math.cos(a) for a in angles_rad]))
    mean_sin = float(np.mean([math.sin(a) for a in angles_rad]))
    mean_resultant = math.sqrt(mean_cos ** 2 + mean_sin ** 2)
    # resultant 1.0 = all motion same direction (linear track), 0.0 = all directions covered

    # Dominant direction
    dominant_angle = math.degrees(math.atan2(mean_sin, mean_cos)) % 360

    # FOE analysis: frames where camera is moving forward/backward
    foe_xs = [r["foe_x"] for r in pair_records if r["foe_x"] is not None]
    foe_ys = [r["foe_y"] for r in pair_records if r["foe_y"] is not None]
    foe_near_center = 0
    if foe_xs:
        foe_near_center = int(
            np.mean([1 if abs(x) < 0.4 and abs(y) < 0.4 else 0
                     for x, y in zip(foe_xs, foe_ys)])
            * 100
        )  # % of pairs where FOE is near centre = forward/backward motion

    return {
        "n_pairs_analyzed": len(pair_records),
        "median_rotation_fraction": round(median_rot_frac, 3),
        "median_translation_px": round(median_trans, 2),
        "mean_translation_px": round(mean_trans, 2),
        "max_translation_px": round(max_trans, 2),
        "static_pair_fraction": round(static_pair_frac, 3),
        "direction_diversity_score": round(direction_diversity, 3),
        "n_directions_covered": n_covered,
        "sector_counts": sector_counts,
        "sector_labels": ["E", "NE", "N", "NW", "W", "SW", "S", "SE"],
        "mean_resultant_length": round(mean_resultant, 3),
        "dominant_direction_deg": round(dominant_angle, 1),
        "forward_backward_pct": foe_near_center,
        "pair_records": pair_records,
    }


def _empty_motion_result() -> dict:
    return {
        "n_pairs_analyzed": 0,
        "median_rotation_fraction": 0.5,
        "median_translation_px": 0.0,
        "mean_translation_px": 0.0,
        "max_translation_px": 0.0,
        "static_pair_fraction": 1.0,
        "direction_diversity_score": 0.0,
        "n_directions_covered": 0,
        "sector_counts": [0] * 8,
        "sector_labels": ["E", "NE", "N", "NW", "W", "SW", "S", "SE"],
        "mean_resultant_length": 0.0,
        "dominant_direction_deg": 0.0,
        "forward_backward_pct": 0,
        "pair_records": [],
    }
