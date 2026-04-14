#!/usr/bin/env python3
"""
Texture analyzer — Layer 3.

Two measurements per frame:

1. Gradient energy (Sobel) — overall structural richness of the frame.
   Low energy = blank walls, overexposed, fog, smooth surfaces.
   COLMAP cannot extract reliable keypoints from these.

2. FAST keypoint density — approximate count of distinctly trackable corners.
   COLMAP uses SIFT which is weaker than FAST at finding candidates but
   FAST density is a fast, reliable proxy for "how many features will COLMAP see".

Outputs:
  gradient_energy_mean / std / min / p10 / p25
  keypoint_density_mean / std / min
  low_texture_frame_count / fraction
  low_texture_frame_names  (for user inspection)
  spatial_coverage_score   (are features spread across the image, or clustered?)
"""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np


_SMALL_W = 320
_FAST_THRESHOLD = 20  # FAST detector sensitivity


def _resize_small(img: np.ndarray) -> np.ndarray:
    h, w = img.shape[:2]
    if w <= _SMALL_W:
        return img
    scale = _SMALL_W / w
    return cv2.resize(img, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)


def _gradient_energy(img_gray: np.ndarray) -> float:
    """Mean of Sobel gradient magnitude (full image)."""
    sx = cv2.Sobel(img_gray, cv2.CV_64F, 1, 0, ksize=3)
    sy = cv2.Sobel(img_gray, cv2.CV_64F, 0, 1, ksize=3)
    mag = np.sqrt(sx ** 2 + sy ** 2)
    return float(mag.mean())


def _keypoint_density(img_gray: np.ndarray) -> int:
    """Number of FAST keypoints detected (proxy for SIFT/COLMAP feature count)."""
    fast = cv2.FastFeatureDetector_create(threshold=_FAST_THRESHOLD, nonmaxSuppression=True)
    kps = fast.detect(img_gray, None)
    return len(kps)


def _spatial_coverage(img_gray: np.ndarray, grid: int = 4) -> float:
    """
    Divide image into grid×grid cells.
    Return fraction of cells that contain at least one FAST keypoint.
    1.0 = features in every quadrant (spatially well-distributed).
    0.0 = all features in one corner.
    """
    h, w = img_gray.shape
    fast = cv2.FastFeatureDetector_create(threshold=_FAST_THRESHOLD, nonmaxSuppression=True)
    kps = fast.detect(img_gray, None)
    if not kps:
        return 0.0

    occupied = set()
    cell_w = w / grid
    cell_h = h / grid
    for kp in kps:
        cx = int(kp.pt[0] / cell_w)
        cy = int(kp.pt[1] / cell_h)
        occupied.add((min(cx, grid - 1), min(cy, grid - 1)))

    return len(occupied) / (grid * grid)


def analyze_texture(
    image_paths: list[Path],
    *,
    low_gradient_threshold: float | None = None,
    low_kp_threshold: int | None = None,
) -> dict:
    """
    Run texture analysis on all frames.

    Thresholds: if None, auto-set to bottom 15th percentile of this run
    (adaptive — works across scenes).
    """
    if not image_paths:
        return _empty_texture_result()

    frame_data: list[dict] = []

    for path in image_paths:
        img = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        if img is None:
            continue
        small = _resize_small(img)
        ge = _gradient_energy(small)
        kp = _keypoint_density(small)
        sc = _spatial_coverage(small)
        frame_data.append(
            {
                "name": path.name,
                "gradient_energy": round(ge, 2),
                "keypoint_count": kp,
                "spatial_coverage": round(sc, 3),
            }
        )

    if not frame_data:
        return _empty_texture_result()

    ges = np.array([f["gradient_energy"] for f in frame_data])
    kps = np.array([f["keypoint_count"] for f in frame_data])
    scs = np.array([f["spatial_coverage"] for f in frame_data])

    # Adaptive thresholds if not provided
    ge_thresh = low_gradient_threshold if low_gradient_threshold is not None else float(np.percentile(ges, 15))
    kp_thresh = low_kp_threshold if low_kp_threshold is not None else max(5, int(np.percentile(kps, 15)))

    low_texture_frames = [
        f for f in frame_data
        if f["gradient_energy"] < ge_thresh or f["keypoint_count"] < kp_thresh
    ]

    return {
        "n_frames": len(frame_data),
        "gradient_energy": {
            "mean": round(float(ges.mean()), 2),
            "std": round(float(ges.std()), 2),
            "min": round(float(ges.min()), 2),
            "p10": round(float(np.percentile(ges, 10)), 2),
            "p25": round(float(np.percentile(ges, 25)), 2),
            "p75": round(float(np.percentile(ges, 75)), 2),
            "max": round(float(ges.max()), 2),
        },
        "keypoint_density": {
            "mean": round(float(kps.mean()), 1),
            "std": round(float(kps.std()), 1),
            "min": int(kps.min()),
            "p10": int(np.percentile(kps, 10)),
            "p25": int(np.percentile(kps, 25)),
        },
        "spatial_coverage": {
            "mean": round(float(scs.mean()), 3),
            "min": round(float(scs.min()), 3),
            "low_coverage_frames": int(np.sum(scs < 0.4)),
        },
        "low_texture_threshold_gradient": round(ge_thresh, 2),
        "low_texture_threshold_keypoints": kp_thresh,
        "low_texture_frame_count": len(low_texture_frames),
        "low_texture_fraction": round(len(low_texture_frames) / len(frame_data), 3),
        "low_texture_frame_names": [f["name"] for f in low_texture_frames],
        "frame_scores": frame_data,
    }


def _empty_texture_result() -> dict:
    return {
        "n_frames": 0,
        "gradient_energy": {},
        "keypoint_density": {},
        "spatial_coverage": {},
        "low_texture_threshold_gradient": 0,
        "low_texture_threshold_keypoints": 0,
        "low_texture_frame_count": 0,
        "low_texture_fraction": 0.0,
        "low_texture_frame_names": [],
        "frame_scores": [],
    }
