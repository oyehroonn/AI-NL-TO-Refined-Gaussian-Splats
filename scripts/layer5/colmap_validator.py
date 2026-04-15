"""
Pre-flight COLMAP output validator.

Checks sparse/0/ before Brush runs so we fail-fast on bad reconstructions
instead of wasting training time on an empty or degenerate scene.
"""
from __future__ import annotations

from pathlib import Path

from .colmap_reader import (
    read_cameras_count,
    read_images_count,
    read_points3d_count,
)

# ── Thresholds ────────────────────────────────────────────────────────────────
_MIN_REGISTERED_IMAGES = 10   # fewer → COLMAP likely failed
_MIN_3D_POINTS        = 200   # fewer → reconstruction is degenerate
_WARN_3D_POINTS       = 1000  # below this → warn (sparse, lower quality)


def validate_colmap(sparse_dir: Path, verbose: bool = True) -> dict:
    """
    Validate a COLMAP sparse/0/ directory.

    Returns:
        {
          "ok": bool,
          "warn": bool,
          "n_cameras": int,
          "n_images": int,
          "n_points": int,
          "errors": [str, ...],
          "warnings": [str, ...],
        }
    """
    sparse_dir = Path(sparse_dir)
    errors: list[str] = []
    warnings: list[str] = []

    n_cameras = n_images = n_points = 0

    for fname in ("cameras.bin", "images.bin", "points3D.bin"):
        fpath = sparse_dir / fname
        if not fpath.exists():
            errors.append(f"Missing {fname} in {sparse_dir}")
        elif fpath.stat().st_size == 0:
            errors.append(f"Empty {fname} — COLMAP wrote no data")

    if errors:
        if verbose:
            for e in errors:
                print(f"[COLMAP validate] ERROR: {e}")
        return {
            "ok": False, "warn": False,
            "n_cameras": 0, "n_images": 0, "n_points": 0,
            "errors": errors, "warnings": warnings,
        }

    try:
        n_cameras = read_cameras_count(sparse_dir / "cameras.bin")
        n_images  = read_images_count(sparse_dir / "images.bin")
        n_points  = read_points3d_count(sparse_dir / "points3D.bin")
    except Exception as e:
        errors.append(f"Failed to read COLMAP binary: {e}")
        return {
            "ok": False, "warn": False,
            "n_cameras": n_cameras, "n_images": n_images, "n_points": n_points,
            "errors": errors, "warnings": warnings,
        }

    if n_cameras == 0:
        errors.append("No cameras registered — COLMAP failed to estimate any poses")
    if n_images < _MIN_REGISTERED_IMAGES:
        errors.append(
            f"Only {n_images} images registered (min {_MIN_REGISTERED_IMAGES}) "
            "— COLMAP reconstruction likely failed or dataset is too small"
        )
    if n_points < _MIN_3D_POINTS:
        errors.append(
            f"Only {n_points} 3D points (min {_MIN_3D_POINTS}) "
            "— reconstruction is degenerate; check COLMAP log"
        )

    if not errors:
        if n_points < _WARN_3D_POINTS:
            warnings.append(
                f"Only {n_points} 3D points (recommended ≥ {_WARN_3D_POINTS}) "
                "— sparse reconstruction; splat quality may be lower"
            )

    ok = len(errors) == 0
    warn = len(warnings) > 0

    if verbose:
        status = "OK" if ok else "FAIL"
        print(
            f"[COLMAP validate] {status} — "
            f"{n_cameras} cameras | {n_images} images | {n_points:,} 3D points"
        )
        for w in warnings:
            print(f"[COLMAP validate] WARN: {w}")
        for e in errors:
            print(f"[COLMAP validate] ERROR: {e}")

    return {
        "ok": ok, "warn": warn,
        "n_cameras": n_cameras,
        "n_images": n_images,
        "n_points": n_points,
        "errors": errors,
        "warnings": warnings,
    }
