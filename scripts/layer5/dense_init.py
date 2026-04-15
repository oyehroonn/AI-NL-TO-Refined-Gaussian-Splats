"""
Dense init.ply generator: DPT depth maps + COLMAP cameras → dense point cloud.

Brush reads init.ply as the starting Gaussian positions instead of the sparse
COLMAP points3D.  More initial points = faster convergence, denser reconstruction,
fewer floaters.

Algorithm
─────────
1. Parse cameras.bin + images.bin from sparse/0/ for camera poses + intrinsics.
2. Parse points3D.bin to compute a depth-scale alignment factor:
   for each COLMAP point observed in image i at pixel (u,v):
     z_colmap  = camera-space depth of the 3D point
     z_dpt_rel = 1 / (dpt_val + eps)           [inverse-depth from MiDaS]
     scale_sample = z_colmap / z_dpt_rel
   scale = median(scale_samples)
3. For each image frame:
   a. Load DPT depth map, resize to camera resolution.
   b. Sample N pixels (skip near-zero = sky/far, skip saturated = too close).
   c. Back-project to COLMAP world coords:
        X_cam   = z_metric * [(u-cx)/fx, (v-cy)/fy, 1]
        X_world = R^T @ (X_cam - t)            [COLMAP convention]
   d. Sample colour from the undistorted image (or source if missing).
4. Write all points as init.ply (format: x y z r g b, float32).

Brush detects init.ply automatically: if exactly one .ply is in the dataset
directory, it is used as the initial point cloud.
"""
from __future__ import annotations

import struct
import time
from pathlib import Path

import cv2
import numpy as np

from .colmap_reader import (
    ColmapCamera,
    ColmapImage,
    qvec2rotmat,
    read_cameras_binary,
    read_images_binary,
    read_points3d_binary,
)

IMAGE_EXTS = frozenset({".jpg", ".jpeg", ".png", ".bmp"})

# ── Depth sampling limits ─────────────────────────────────────────────────────
_DPT_MIN = 0.05   # ignore near-zero depth (far / sky / background)
_DPT_MAX = 0.97   # ignore saturated near values (can be unstable after inversion)
_SCALE_MIN_SAMPLES = 20   # need at least this many scale pairs; else skip dense init


# ── PLY writer ────────────────────────────────────────────────────────────────

def _write_ply(path: Path, xyz: np.ndarray, rgb: np.ndarray) -> None:
    """
    Write a binary-little-endian PLY with properties:
        float x, float y, float z, float red, float green, float blue

    Brush's serde-ply reads `red/green/blue` as float32 (0.0–1.0) and
    converts to SH DC coefficients via rgb_to_sh().  All other Gaussian
    attributes (scale, opacity, rotation) default to 0 and are initialised
    by Splats::from_raw().

    xyz : (N, 3) float32  — world coords in COLMAP frame
    rgb : (N, 3) float32  — colours in [0, 1]
    """
    n = len(xyz)
    header = (
        "ply\n"
        "format binary_little_endian 1.0\n"
        f"element vertex {n}\n"
        "property float x\n"
        "property float y\n"
        "property float z\n"
        "property float red\n"
        "property float green\n"
        "property float blue\n"
        "end_header\n"
    ).encode("ascii")

    # Interleave xyz + rgb → (N, 6) float32 → flat bytes
    data = np.concatenate([xyz.astype(np.float32), rgb.astype(np.float32)], axis=1)
    with open(path, "wb") as f:
        f.write(header)
        f.write(data.tobytes())


# ── Image lookup ──────────────────────────────────────────────────────────────

def _find_image(search_dirs: list[Path], name: str) -> Path | None:
    """
    Find an image by name (or stem) across multiple candidate directories.
    COLMAP stores names like 'frame_000001.jpg'; after undistortion the file
    is in images/ with the same name.
    """
    stem = Path(name).stem
    for d in search_dirs:
        if not d.is_dir():
            continue
        # exact name match
        p = d / name
        if p.exists():
            return p
        # stem + any extension
        for ext in IMAGE_EXTS:
            p = d / (stem + ext)
            if p.exists():
                return p
    return None


# ── Scale alignment ───────────────────────────────────────────────────────────

def _compute_depth_scale(
    cameras: dict[int, ColmapCamera],
    images: dict[int, ColmapImage],
    points3d: dict,
    dpt_map: dict[str, Path],
    max_samples_per_image: int = 200,
) -> float | None:
    """
    Align MiDaS inverse-depth to COLMAP metric depth.

    Returns the median scale factor (z_colmap / z_midas_relative),
    or None if not enough observations were found.
    """
    scales: list[float] = []

    for img in images.values():
        cam = cameras.get(img.camera_id)
        if cam is None:
            continue

        stem = Path(img.name).stem
        if stem not in dpt_map:
            continue

        dpt_raw = cv2.imread(str(dpt_map[stem]), cv2.IMREAD_GRAYSCALE)
        if dpt_raw is None:
            continue

        # Resize DPT to camera image dimensions
        if dpt_raw.shape != (cam.height, cam.width):
            dpt_raw = cv2.resize(dpt_raw, (cam.width, cam.height), interpolation=cv2.INTER_LINEAR)
        dpt_f = dpt_raw.astype(np.float32) / 255.0

        R = qvec2rotmat(img.qvec)   # 3×3  (X_cam = R @ X_world + t)
        t = np.array(img.tvec)       # (3,)

        sampled = 0
        for (u, v), p3d_id in zip(img.xys, img.point3d_ids):
            if p3d_id == -1 or p3d_id not in points3d:
                continue

            pt_world = np.array(points3d[p3d_id].xyz)
            pt_cam   = R @ pt_world + t
            z_colmap = pt_cam[2]
            if z_colmap <= 0:
                continue

            ui = int(round(u))
            vi = int(round(v))
            if not (0 <= ui < cam.width and 0 <= vi < cam.height):
                continue

            d_val = float(dpt_f[vi, ui])
            if d_val < _DPT_MIN:
                continue  # too far / sky

            z_rel = 1.0 / (d_val + 1e-6)
            scales.append(z_colmap / z_rel)
            sampled += 1
            if sampled >= max_samples_per_image:
                break

    if len(scales) < _SCALE_MIN_SAMPLES:
        return None

    return float(np.median(scales))


# ── Main entry ────────────────────────────────────────────────────────────────

def generate_dense_init(
    run_dir: Path,
    sparse_dir: Path,
    dpt_dir: Path,
    *,
    n_samples_per_frame: int = 2000,
    verbose: bool = True,
) -> dict:
    """
    Generate init.ply from DPT depth maps and COLMAP camera poses.

    run_dir    : the pipeline run directory (init.ply is written here)
    sparse_dir : sparse/0/ directory with cameras.bin / images.bin / points3D.bin
    dpt_dir    : dpt/ directory with <stem>.png depth maps
    n_samples_per_frame : points sampled per image (total ≈ n_frames × this)

    Returns a stats dict.  On failure returns {"error": ..., "n_points": 0}.
    """
    run_dir    = run_dir.resolve()
    sparse_dir = sparse_dir.resolve()
    dpt_dir    = dpt_dir.resolve()

    if not dpt_dir.is_dir():
        return {"error": "dpt_dir does not exist — run Layer 4 first", "n_points": 0}

    dpt_files = {p.stem: p for p in dpt_dir.iterdir() if p.suffix.lower() == ".png"}
    if not dpt_files:
        return {"error": "No depth maps in dpt_dir", "n_points": 0}

    # ── Load COLMAP data ──────────────────────────────────────────────────────
    try:
        if verbose:
            print("[Layer 5 dense init] Loading COLMAP cameras / images / points3D …")
        cameras  = read_cameras_binary(sparse_dir / "cameras.bin")
        images   = read_images_binary(sparse_dir / "images.bin")
        points3d = read_points3d_binary(sparse_dir / "points3D.bin", max_points=50_000)
    except Exception as e:
        return {"error": f"COLMAP binary read failed: {e}", "n_points": 0}

    if verbose:
        print(f"[Layer 5 dense init]   {len(cameras)} cameras | {len(images)} images | {len(points3d):,} 3D points")

    # ── Image search dirs (undistorted images/ first, source/ as fallback) ────
    image_search = [run_dir / "images", run_dir / "source"]

    # ── Compute depth scale alignment ─────────────────────────────────────────
    t0 = time.perf_counter()
    if verbose:
        print("[Layer 5 dense init] Computing DPT → COLMAP depth scale …")

    scale = _compute_depth_scale(cameras, images, points3d, dpt_files)
    if scale is None:
        return {
            "error": (
                f"Not enough scale samples (need ≥ {_SCALE_MIN_SAMPLES} COLMAP↔DPT correspondences). "
                "Ensure DPT stem names match COLMAP image names."
            ),
            "n_points": 0,
        }

    if verbose:
        print(f"[Layer 5 dense init]   depth scale = {scale:.4f}")

    # ── Back-project all frames ───────────────────────────────────────────────
    all_xyz: list[np.ndarray] = []
    all_rgb: list[np.ndarray] = []
    n_frames_used = 0

    rng = np.random.default_rng(seed=42)

    for img in images.values():
        cam = cameras.get(img.camera_id)
        if cam is None:
            continue

        stem = Path(img.name).stem
        if stem not in dpt_files:
            continue

        # Load DPT
        dpt_raw = cv2.imread(str(dpt_files[stem]), cv2.IMREAD_GRAYSCALE)
        if dpt_raw is None:
            continue
        if dpt_raw.shape != (cam.height, cam.width):
            dpt_raw = cv2.resize(dpt_raw, (cam.width, cam.height), interpolation=cv2.INTER_LINEAR)
        dpt_f = dpt_raw.astype(np.float32) / 255.0

        # Load colour image
        img_path = _find_image(image_search, img.name)
        if img_path is None:
            continue
        img_bgr = cv2.imread(str(img_path))
        if img_bgr is None:
            continue

        # Resize colour to camera resolution if needed
        if img_bgr.shape[:2] != (cam.height, cam.width):
            img_bgr = cv2.resize(img_bgr, (cam.width, cam.height), interpolation=cv2.INTER_LINEAR)

        # Valid pixel mask: exclude sky/far and over-close saturated regions
        valid = (dpt_f > _DPT_MIN) & (dpt_f < _DPT_MAX)
        valid_ys, valid_xs = np.where(valid)

        if len(valid_ys) < 10:
            continue

        # Random sample
        n = min(n_samples_per_frame, len(valid_ys))
        idx = rng.choice(len(valid_ys), size=n, replace=False)
        rows = valid_ys[idx]
        cols = valid_xs[idx]

        # Depth → metric
        d_vals = dpt_f[rows, cols]
        z_metric = (1.0 / (d_vals + 1e-6)) * scale  # (N,)

        # Back-project to camera space
        x_cam = (cols.astype(np.float64) - cam.cx) / cam.fx * z_metric
        y_cam = (rows.astype(np.float64) - cam.cy) / cam.fy * z_metric
        z_cam = z_metric
        pts_cam = np.stack([x_cam, y_cam, z_cam], axis=1)   # (N, 3)

        # Transform to world: X_world = R^T @ (X_cam - t)
        R = qvec2rotmat(img.qvec)
        t = np.array(img.tvec)
        pts_world = (pts_cam - t[None, :]) @ R   # R^T applied by right-multiply

        # Colours (BGR → RGB, 0-1)
        r_ch = img_bgr[rows, cols, 2].astype(np.float32) / 255.0
        g_ch = img_bgr[rows, cols, 1].astype(np.float32) / 255.0
        b_ch = img_bgr[rows, cols, 0].astype(np.float32) / 255.0
        colors = np.stack([r_ch, g_ch, b_ch], axis=1)   # (N, 3)

        all_xyz.append(pts_world.astype(np.float32))
        all_rgb.append(colors)
        n_frames_used += 1

    if not all_xyz:
        return {"error": "No frames could be back-projected", "n_points": 0}

    xyz = np.concatenate(all_xyz, axis=0)
    rgb = np.concatenate(all_rgb, axis=0)

    # ── Filter outliers: keep points within 4 std of median position ─────────
    center  = np.median(xyz, axis=0)
    dists   = np.linalg.norm(xyz - center[None, :], axis=1)
    thresh  = np.median(dists) + 4.0 * dists.std()
    keep    = dists < thresh
    xyz = xyz[keep]
    rgb = rgb[keep]

    # ── Write PLY ─────────────────────────────────────────────────────────────
    init_ply = run_dir / "init.ply"
    _write_ply(init_ply, xyz, rgb)

    elapsed = time.perf_counter() - t0

    if verbose:
        print(
            f"[Layer 5 dense init] Done: {len(xyz):,} points from {n_frames_used} frames "
            f"({elapsed:.1f}s) → {init_ply}"
        )

    return {
        "n_points": int(len(xyz)),
        "n_frames_used": n_frames_used,
        "depth_scale": round(float(scale), 5),
        "outliers_removed": int(keep.size - keep.sum()),
        "output_path": str(init_ply),
        "elapsed_seconds": round(elapsed, 2),
    }
