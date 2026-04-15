"""
Layer 6 — Coverage Analyzer.

Tests every Gaussian against every COLMAP camera frustum to find:
  - Gaussians seen by 0 cameras  → hallucinated geometry
  - Gaussians seen by ≤2 cameras → weakly constrained
  - Mean visibility per Gaussian → overall coverage health

Reuses layer5.colmap_reader (already in sys.path via pipeline).
No extra deps beyond numpy + stdlib.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np


def analyze_coverage(
    sparse_dir: Path,
    ply_analysis: dict,
    *,
    verbose: bool = False,
) -> dict:
    """
    Parameters
    ----------
    sparse_dir   : path to sparse/0/  (contains cameras.bin + images.bin)
    ply_analysis : output dict from ply_analyzer.analyze_ply
                   must contain _positions (N×3 float32 numpy array)
    verbose      : print progress lines

    Returns
    -------
    dict with visibility_stats, camera_stats, weak_zone, _visibility_count
    """
    result: dict = {"ok": False, "error": None}

    pos: np.ndarray | None = ply_analysis.get("_positions")
    if pos is None:
        result["error"] = "No position data from PLY analyzer"
        return result

    # ── Load COLMAP binary data ───────────────────────────────────────────────
    try:
        from layer5.colmap_reader import (
            read_cameras_binary,
            read_images_binary,
            qvec2rotmat,
        )
    except ImportError:
        result["error"] = "layer5.colmap_reader not importable — check sys.path"
        return result

    cameras_bin = sparse_dir / "cameras.bin"
    images_bin  = sparse_dir / "images.bin"
    if not cameras_bin.is_file() or not images_bin.is_file():
        result["error"] = f"COLMAP binary files not found in {sparse_dir}"
        return result

    cameras = read_cameras_binary(cameras_bin)
    images  = read_images_binary(images_bin)

    n_cameras = len(images)
    n_gauss   = len(pos)
    result["n_cameras"]   = n_cameras
    result["n_gaussians"] = n_gauss

    if n_cameras == 0:
        result["error"] = "No COLMAP cameras found"
        return result

    if verbose:
        print(f"  [coverage] {n_gauss:,} Gaussians × {n_cameras} cameras")

    # ── Camera world positions ────────────────────────────────────────────────
    cam_positions: list[np.ndarray] = []
    for img in images.values():
        R = qvec2rotmat(img.qvec)
        t = np.array(img.tvec)
        cam_positions.append(-R.T @ t)   # world position = -R^T t

    cam_pos_arr = np.array(cam_positions)        # (C, 3)
    cam_centroid = cam_pos_arr.mean(axis=0)
    cam_spread   = float(np.linalg.norm(cam_pos_arr - cam_centroid, axis=1).mean())

    # ── Frustum visibility (vectorised, batched) ──────────────────────────────
    BATCH = 8_000
    visibility_count = np.zeros(n_gauss, dtype=np.int32)
    pos_f64 = pos.astype(np.float64)

    for img in images.values():
        cam = cameras.get(img.camera_id)
        if cam is None:
            continue

        R   = qvec2rotmat(img.qvec)               # (3,3)
        t   = np.array(img.tvec, dtype=np.float64) # (3,)
        fx, fy  = cam.fx, cam.fy
        cx, cy  = cam.cx, cam.cy
        W,  H   = cam.width, cam.height

        for start in range(0, n_gauss, BATCH):
            end   = min(start + BATCH, n_gauss)
            batch = pos_f64[start:end]          # (B, 3)

            # Camera space: x_cam = R @ x_world + t
            x_cam = (R @ batch.T).T + t         # (B, 3)
            z     = x_cam[:, 2]
            in_front = z > 0.01

            # Safe divide — use 1.0 where z ≤ 0.01 (result masked out anyway)
            z_safe = np.where(in_front, z, 1.0)
            u = fx * x_cam[:, 0] / z_safe + cx
            v = fy * x_cam[:, 1] / z_safe + cy

            in_frustum = in_front & (u >= 0) & (u < W) & (v >= 0) & (v < H)
            visibility_count[start:end] += in_frustum.astype(np.int32)

    if verbose:
        print(f"  [coverage] scan complete")

    # ── Visibility statistics ─────────────────────────────────────────────────
    n_unseen    = int((visibility_count == 0).sum())
    n_single    = int((visibility_count == 1).sum())
    n_weak      = int((visibility_count <= 2).sum())
    n_well_seen = int((visibility_count >= 3).sum())
    mean_vis    = float(visibility_count.mean())
    max_vis     = int(visibility_count.max())

    result["visibility_stats"] = {
        "unseen_count":          n_unseen,
        "unseen_fraction":       round(n_unseen   / n_gauss, 4),
        "single_view_count":     n_single,
        "single_view_fraction":  round(n_single   / n_gauss, 4),
        "weak_count":            n_weak,
        "weak_fraction":         round(n_weak     / n_gauss, 4),
        "well_seen_count":       n_well_seen,
        "well_seen_fraction":    round(n_well_seen / n_gauss, 4),
        "mean_visibility":       round(mean_vis, 2),
        "max_visibility":        max_vis,
    }

    # ── Camera spread metrics ─────────────────────────────────────────────────
    result["camera_stats"] = {
        "n_cameras":   n_cameras,
        "centroid":    cam_centroid.tolist(),
        "mean_spread": round(cam_spread, 4),
    }

    # ── Spatial weak zone (centroid of unseen/single-view Gaussians) ──────────
    weak_mask = visibility_count <= 1
    if weak_mask.sum() > 10:
        weak_pos      = pos[weak_mask]
        weak_centroid = weak_pos.mean(axis=0)
        weak_spread   = float(np.linalg.norm(weak_pos - weak_centroid, axis=1).mean())
        result["weak_zone"] = {
            "centroid":    weak_centroid.tolist(),
            "spread":      round(weak_spread, 4),
            "n_gaussians": int(weak_mask.sum()),
        }
    else:
        result["weak_zone"] = None

    # Internal array — stripped before JSON write
    result["_visibility_count"] = visibility_count

    result["ok"] = True
    return result
