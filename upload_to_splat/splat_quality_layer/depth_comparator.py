"""
Layer 6 — Depth Comparator.

Compares DPT monocular depth maps (from Layer 4) against the Gaussian
positions to detect depth mismatches: Gaussians forming at the wrong
depth layer.

Method:
  For each camera (up to max_cameras sampled), project every Gaussian into
  camera-image-space and compute an expected depth from DPT. Compare actual
  Gaussian depth (Z in camera space) vs DPT depth at that pixel.

  Because DPT produces inverse-relative depth (0–255, 255=closest), we
  first align scales using a RANSAC median ratio before comparing.

Output:
  - Per-camera mismatch score (fraction of Gaussians with depth error > thresh)
  - Global mismatch fraction
  - Worst camera zones (camera names with highest mismatch)

Deps: numpy + cv2.
"""
from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np


def _load_dpt(dpt_path: Path) -> np.ndarray | None:
    """Load DPT depth map as float32 in [0, 255]."""
    img = cv2.imread(str(dpt_path), cv2.IMREAD_GRAYSCALE)
    if img is None:
        return None
    return img.astype(np.float32)


def analyze_depth(
    run_dir: Path,
    ply_analysis: dict,
    *,
    max_cameras: int = 20,
    depth_error_threshold: float = 0.25,
    verbose: bool = False,
) -> dict:
    """
    Parameters
    ----------
    run_dir                : pipeline run root (contains dpt/ and sparse/0/)
    ply_analysis           : output of ply_analyzer.analyze_ply (needs _positions)
    max_cameras            : cap cameras to analyze (slow if all 100+)
    depth_error_threshold  : relative depth error above which Gaussian is
                             considered mismatched (0.25 = 25 % relative error)
    verbose                : print progress

    Returns
    -------
    dict with ok, available, global_mismatch_fraction, per_camera_stats,
    worst_cameras, _depth_mismatch_mask
    """
    result: dict = {"ok": False, "error": None, "available": False}

    pos: np.ndarray | None = ply_analysis.get("_positions")
    if pos is None:
        result["error"] = "No position data from PLY analyzer"
        return result

    dpt_dir = run_dir / "dpt"
    if not dpt_dir.is_dir():
        result["error"] = "No dpt/ directory found — Layer 4 may not have run"
        return result

    dpt_files = sorted(dpt_dir.glob("*.png"))
    if not dpt_files:
        result["error"] = "dpt/ directory is empty"
        return result

    result["available"] = True

    # ── Load COLMAP cameras ───────────────────────────────────────────────────
    try:
        from brush_packaging_layer.colmap_reader import (
            read_cameras_binary,
            read_images_binary,
            qvec2rotmat,
        )
    except ImportError:
        result["error"] = "brush_packaging_layer.colmap_reader not importable"
        return result

    sparse_dir = run_dir / "sparse" / "0"
    cameras_bin = sparse_dir / "cameras.bin"
    images_bin  = sparse_dir / "images.bin"
    if not cameras_bin.is_file() or not images_bin.is_file():
        result["error"] = f"COLMAP binaries not found in {sparse_dir}"
        return result

    cameras = read_cameras_binary(cameras_bin)
    images  = read_images_binary(images_bin)

    if not images:
        result["error"] = "No COLMAP images loaded"
        return result

    # ── Index DPT files by stem ───────────────────────────────────────────────
    dpt_index: dict[str, Path] = {p.stem.lower(): p for p in dpt_files}

    # ── Sample cameras ────────────────────────────────────────────────────────
    all_imgs = list(images.values())
    if len(all_imgs) > max_cameras:
        rng  = np.random.default_rng(42)
        idxs = rng.choice(len(all_imgs), max_cameras, replace=False)
        all_imgs = [all_imgs[i] for i in sorted(idxs)]

    if verbose:
        print(f"  [depth] comparing {len(pos):,} Gaussians × {len(all_imgs)} cameras")

    pos_f64 = pos.astype(np.float64)
    n_gauss = len(pos_f64)

    # Track per-Gaussian: accumulated mismatch votes
    mismatch_votes = np.zeros(n_gauss, dtype=np.int32)
    camera_count   = np.zeros(n_gauss, dtype=np.int32)

    per_camera_stats: list[dict] = []

    BATCH = 8_000
    for img in all_imgs:
        cam = cameras.get(img.camera_id)
        if cam is None:
            continue

        # Match image stem to DPT file
        img_stem = Path(img.name).stem.lower()
        dpt_path = dpt_index.get(img_stem)
        if dpt_path is None:
            continue

        dpt_map = _load_dpt(dpt_path)
        if dpt_map is None:
            continue

        H_dpt, W_dpt = dpt_map.shape
        R  = qvec2rotmat(img.qvec)
        t  = np.array(img.tvec, dtype=np.float64)
        fx, fy = cam.fx, cam.fy
        cx, cy = cam.cx, cam.cy
        W, H   = cam.width, cam.height

        cam_depth_vals: list[float] = []
        dpt_depth_vals: list[float] = []
        gauss_in_cam:   list[int]   = []

        for start in range(0, n_gauss, BATCH):
            end   = min(start + BATCH, n_gauss)
            batch = pos_f64[start:end]

            x_cam = (R @ batch.T).T + t
            z     = x_cam[:, 2]
            in_front = z > 0.01

            z_safe = np.where(in_front, z, 1.0)
            u = fx * x_cam[:, 0] / z_safe + cx
            v = fy * x_cam[:, 1] / z_safe + cy

            in_frustum = (
                in_front
                & (u >= 0) & (u < W)
                & (v >= 0) & (v < H)
            )

            idxs_in = np.where(in_frustum)[0] + start
            for i_local, i_global in enumerate(np.where(in_frustum)[0]):
                u_px = int(u[i_local] * W_dpt / W)
                v_px = int(v[i_local] * H_dpt / H)
                u_px = min(max(u_px, 0), W_dpt - 1)
                v_px = min(max(v_px, 0), H_dpt - 1)

                dpt_val = float(dpt_map[v_px, u_px])
                z_val   = float(z[i_local])

                cam_depth_vals.append(z_val)
                dpt_depth_vals.append(dpt_val)
                gauss_in_cam.append(i_global)

        if len(cam_depth_vals) < 10:
            continue

        # Scale alignment: DPT is inverse-relative depth (255=closest)
        # Convert to "closer = smaller" by inverting: dpt_depth → (255-dpt) + 1
        cam_arr = np.array(cam_depth_vals, dtype=np.float64)
        dpt_arr = np.array(dpt_depth_vals, dtype=np.float64)
        dpt_inv = 256.0 - dpt_arr   # now larger = farther (same direction as Z)

        # Align scale: median ratio
        valid = (dpt_inv > 1.0) & (cam_arr > 0.001)
        if valid.sum() < 5:
            continue

        ratios = cam_arr[valid] / dpt_inv[valid]
        scale  = float(np.median(ratios))

        if scale <= 0 or not np.isfinite(scale):
            continue

        dpt_scaled = dpt_inv * scale
        rel_error  = np.abs(cam_arr - dpt_scaled) / (cam_arr + 1e-6)
        mismatched = rel_error > depth_error_threshold

        n_in_cam  = len(gauss_in_cam)
        n_mismatch = int(mismatched.sum())
        frac = n_mismatch / max(n_in_cam, 1)

        for k, g_idx in enumerate(gauss_in_cam):
            camera_count[g_idx]  += 1
            if mismatched[k]:
                mismatch_votes[g_idx] += 1

        per_camera_stats.append({
            "image_name":          img.name,
            "n_gaussians_in_view": n_in_cam,
            "mismatch_count":      n_mismatch,
            "mismatch_fraction":   round(frac, 4),
            "scale_factor":        round(scale, 4),
        })

    if not per_camera_stats:
        result["error"] = "Could not match any DPT file to COLMAP images"
        return result

    # ── Global mismatch fraction ──────────────────────────────────────────────
    seen_mask   = camera_count > 0
    n_seen      = int(seen_mask.sum())
    ratio_arr   = np.where(seen_mask, mismatch_votes / np.maximum(camera_count, 1), 0.0)
    high_mismatch_mask = ratio_arr > 0.5   # >50% of cameras agree it's wrong

    global_mismatch_frac = float(high_mismatch_mask.sum()) / max(n_seen, 1)

    # Worst 5 cameras by mismatch fraction
    worst = sorted(per_camera_stats, key=lambda c: c["mismatch_fraction"], reverse=True)[:5]

    result["n_cameras_analyzed"] = len(per_camera_stats)
    result["global_mismatch_fraction"] = round(global_mismatch_frac, 4)
    result["depth_error_threshold"]    = depth_error_threshold
    result["per_camera_stats"]         = per_camera_stats
    result["worst_cameras"]            = worst
    result["_depth_mismatch_mask"]     = high_mismatch_mask

    result["ok"] = True
    return result
