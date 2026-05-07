#!/usr/bin/env python3
"""AR-Layer 4 orchestrator.

Converts an `ar_runs/<id>/capture/` directory into a COLMAP-shaped run dir
under `runs/<new_id>/` so the existing splat pipeline trains on it
unchanged.

Usage (from repo root):
    python3 -m ar_capture_to_splat.scripts.pose_bridge_layer.run_layer4 \
        --ar-run-dir ar_runs/run6__MyDrawing                # symlink frames

    python3 -m ar_capture_to_splat.scripts.pose_bridge_layer.run_layer4 \
        --ar-run-dir ar_runs/run6__MyDrawing --copy         # copy frames
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

# Make the orchestrator runnable both as `python -m ...` and as a script.
_HERE = Path(__file__).resolve()
_REPO_ROOT = _HERE.parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from ar_capture_to_splat.scripts.pose_bridge_layer.ar_run_reader import (   # noqa: E402
    feature_point_files_by_frame_id,
    load_ar_run,
    ARFrameRecord,
)
from ar_capture_to_splat.scripts.pose_bridge_layer.colmap_writers import (  # noqa: E402
    CAMERA_MODEL_PINHOLE,
    CameraRecord,
    ImagePoint2D,
    ImageRecord,
    Point3DRecord,
    TrackEntry,
    write_cameras_bin,
    write_images_bin,
    write_points3D_bin,
)
from ar_capture_to_splat.scripts.pose_bridge_layer.feature_points_loader import (  # noqa: E402
    aggregate_by_identifier,
)
from ar_capture_to_splat.scripts.pose_bridge_layer.pose_conversion import (  # noqa: E402
    arkit_c2w_to_colmap_w2c,
    project_world_point_to_pixel,
)


log = logging.getLogger("ar_layer4")


# ── Helpers ───────────────────────────────────────────────────────────────────


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _intrinsics_key(K: list[list[float]], width: int, height: int) -> tuple:
    """Two frames share a camera record iff their intrinsics + size match
    to 4 decimals. Avoids floating-point dedup misses."""
    return (
        round(K[0][0], 4), round(K[1][1], 4),
        round(K[0][2], 4), round(K[1][2], 4),
        int(width), int(height),
    )


def _next_run_id(runs_root: Path, video_name: str) -> str:
    """Reuse the alphabetic A0/A1/.../Z10/AA0 sequence the main pipeline uses.

    Imports `default_run_id` lazily so this module stays usable when the
    pipeline package isn't on the path (e.g. tests).
    """
    try:
        from pipeline.run_pipeline import default_run_id   # noqa: WPS433
        return default_run_id(Path(f"{video_name}.mp4"), runs_root=runs_root)
    except Exception:   # noqa: BLE001
        # Safe fallback: timestamp-prefixed.
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        return f"{ts}_{video_name}"


def _safe_basename(name: str) -> str:
    out = []
    for c in name:
        if c.isalnum() or c in ("-", "_", "."):
            out.append(c)
        else:
            out.append("_")
    return ("".join(out).strip("._"))[:48] or "ar_capture"


def _link_or_copy(src: Path, dst: Path, mode: Literal["copy", "symlink"]) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() or dst.is_symlink():
        dst.unlink()
    if mode == "symlink":
        # Use absolute symlink so moving the dataset dir doesn't break the run.
        try:
            os.symlink(src.resolve(), dst)
            return
        except OSError:
            # Fall through to copy on platforms without symlink support
            # (Windows non-admin).
            pass
    shutil.copy2(src, dst)


# ── Main entry ────────────────────────────────────────────────────────────────


def run_layer4(
    ar_run_dir: Path,
    *,
    runs_root: Path | None = None,
    copy_mode: Literal["copy", "symlink"] = "symlink",
    verbose: bool = True,
) -> dict:
    """Convert ar_run_dir/capture/ → runs/<new_id>/ with COLMAP layout.

    Returns a summary dict mirroring metadata/layer4_pose_bridge.json.
    """
    t_start = time.perf_counter()
    ar_run_dir = ar_run_dir.resolve()
    if runs_root is None:
        runs_root = _REPO_ROOT / "runs"
    runs_root = runs_root.resolve()
    runs_root.mkdir(parents=True, exist_ok=True)

    if verbose:
        print(f"\n[Layer 4] Pose-bridge starting on {ar_run_dir.name}")

    # ── 1. Load AR run + manifest ─────────────────────────────────────────────
    ar_run = load_ar_run(ar_run_dir)
    manifest = ar_run.manifest
    n_accepted = len(ar_run.accepted_frames)
    if verbose:
        print(f"[Layer 4] {n_accepted} accepted frames "
              f"(world_map={ar_run.has_world_map}, mesh={ar_run.has_mesh})")

    # ── 2. Allocate the destination run dir ───────────────────────────────────
    video_name = _safe_basename(manifest.get("video_name") or "ar_capture")
    new_run_id = _next_run_id(runs_root, video_name)
    run_dir = runs_root / new_run_id
    if run_dir.exists():
        raise FileExistsError(f"Run directory already exists: {run_dir}")
    images_dir = run_dir / "images"
    sparse_dir = run_dir / "sparse" / "0"
    meta_dir = run_dir / "metadata"
    logs_dir = run_dir / "logs"
    input_dir = run_dir / "input"
    for d in (images_dir, sparse_dir, meta_dir, logs_dir, input_dir):
        d.mkdir(parents=True, exist_ok=True)

    if verbose:
        print(f"[Layer 4] Writing to {run_dir.relative_to(_REPO_ROOT)}/")

    _setup_layer4_log(logs_dir / "layer4.log")

    # ── 3. Camera dedup + COLMAP camera records ──────────────────────────────
    camera_id_by_key: dict[tuple, int] = {}
    cameras: list[CameraRecord] = []

    def _camera_id_for(fr: ARFrameRecord) -> int:
        key = _intrinsics_key(fr.camera_intrinsics, fr.width, fr.height)
        cid = camera_id_by_key.get(key)
        if cid is None:
            cid = len(cameras) + 1   # COLMAP camera ids are 1-based
            camera_id_by_key[key] = cid
            fx = fr.camera_intrinsics[0][0]
            fy = fr.camera_intrinsics[1][1]
            cx = fr.camera_intrinsics[0][2]
            cy = fr.camera_intrinsics[1][2]
            cameras.append(CameraRecord(
                camera_id=cid,
                model_id=CAMERA_MODEL_PINHOLE,
                width=fr.width,
                height=fr.height,
                params=[fx, fy, cx, cy],
            ))
        return cid

    # ── 4. Per-frame: pose conversion + image staging ────────────────────────
    image_records: list[ImageRecord] = []
    image_id_by_frame_id: dict[int, int] = {}
    colmap_w2c_by_frame: dict[int, list[list[float]]] = {}
    intrinsics_by_frame: dict[int, list[list[float]]] = {}
    size_by_frame: dict[int, tuple[int, int]] = {}

    for img_idx, fr in enumerate(ar_run.accepted_frames, start=1):
        cam_id = _camera_id_for(fr)

        try:
            qvec, tvec, w2c = arkit_c2w_to_colmap_w2c(fr.camera_transform_world)
        except Exception as e:   # noqa: BLE001
            log.warning("Skipping frame %s: pose convert failed: %r", fr.frame_id, e)
            continue

        # Stage the JPEG into images/ with COLMAP-friendly stable name.
        src_jpg = ar_run.capture_dir / fr.image_path
        if not src_jpg.is_file():
            log.warning("Skipping frame %s: missing JPEG at %s", fr.frame_id, src_jpg)
            continue

        target_name = Path(fr.image_path).name   # frame_000074.jpg
        _link_or_copy(src_jpg, images_dir / target_name, copy_mode)

        image_records.append(ImageRecord(
            image_id=img_idx,
            qvec=qvec,
            tvec=tvec,
            camera_id=cam_id,
            name=target_name,
            points2D=[],   # filled in below once we have the points3D set
        ))
        image_id_by_frame_id[fr.frame_id] = img_idx
        colmap_w2c_by_frame[fr.frame_id] = w2c
        intrinsics_by_frame[fr.frame_id] = fr.camera_intrinsics
        size_by_frame[fr.frame_id] = (fr.width, fr.height)

    if verbose:
        print(f"[Layer 4] {len(cameras)} unique camera(s); "
              f"{len(image_records)} images staged")

    # ── 5. Build points3D from rawFeaturePoints aggregation ──────────────────
    fp_files = feature_point_files_by_frame_id(ar_run)
    point_groups = aggregate_by_identifier(fp_files, min_track_length=2) if fp_files else {}

    points3D: list[Point3DRecord] = []
    point_id_to_world: dict[int, tuple[float, float, float]] = {}
    next_pt3d_id = 1
    pt3d_to_track_appearance: dict[int, set[int]] = {}   # pt3d → frames

    for ident, info in point_groups.items():
        xyz = info["xyz_world"]
        frames_seen = set(info["frames"])
        # We must observe at least 2 frames whose images we actually staged.
        seen_in_staged = {f for f in frames_seen if f in image_id_by_frame_id}
        if len(seen_in_staged) < 2:
            continue
        pt3d_id = next_pt3d_id
        next_pt3d_id += 1
        pt3d_to_track_appearance[pt3d_id] = seen_in_staged
        point_id_to_world[pt3d_id] = xyz
        # We don't have RGB samples; use neutral grey. COLMAP doesn't error.
        points3D.append(Point3DRecord(
            point3D_id=pt3d_id,
            xyz=xyz,
            rgb=(160, 160, 160),
            error=1.0,
            track=[],   # filled in below
        ))

    if verbose:
        print(f"[Layer 4] {len(points3D)} points3D from feature-point fusion "
              f"(track length ≥ 2)")

    # ── 6. Re-project: per-image points2D + points3D track ───────────────────
    # For each (image, point3D) pair where the point's id appeared in this
    # image's feature dump, project the world-space xyz through the COLMAP
    # camera and write a points2D entry. Also attach (image_id, idx) to the
    # point's track so points3D.bin carries proper visibility.
    image_record_by_id = {rec.image_id: rec for rec in image_records}
    for pt3d in points3D:
        ws = point_id_to_world[pt3d.point3D_id]
        for frame_id in pt3d_to_track_appearance[pt3d.point3D_id]:
            img_id = image_id_by_frame_id[frame_id]
            w2c = colmap_w2c_by_frame[frame_id]
            K = intrinsics_by_frame[frame_id]
            W, H = size_by_frame[frame_id]
            uv = project_world_point_to_pixel(ws, w2c, K, W, H)
            if uv is None:
                # Behind the camera or outside the image — skip this obs.
                continue
            rec = image_record_by_id[img_id]
            point2D_idx = len(rec.points2D)
            rec.points2D.append(ImagePoint2D(
                x=uv[0], y=uv[1], point3D_id=pt3d.point3D_id,
            ))
            pt3d.track.append(TrackEntry(image_id=img_id, point2D_idx=point2D_idx))

    # Drop points whose tracks all projected outside every image.
    points3D = [pt for pt in points3D if len(pt.track) >= 2]
    if verbose:
        print(f"[Layer 4] {len(points3D)} points3D survived re-projection")

    # ── 7. Write COLMAP binaries ──────────────────────────────────────────────
    write_cameras_bin(sparse_dir / "cameras.bin", cameras)
    write_images_bin(sparse_dir / "images.bin", image_records)
    write_points3D_bin(sparse_dir / "points3D.bin", points3D)

    # ── 8. Mirror the run-metadata shape upload pipeline expects ─────────────
    elapsed = time.perf_counter() - t_start
    track_lengths = [len(pt.track) for pt in points3D]
    mean_track_len = (sum(track_lengths) / len(track_lengths)) if track_lengths else 0.0

    summary = {
        "source": "ar",
        "ar_run_id": ar_run_dir.name,
        "ar_session_id": manifest.get("session_id"),
        "scene_type": manifest.get("scene_type"),
        "n_frames_in_manifest": len(manifest.get("frames") or []),
        "n_frames_accepted": n_accepted,
        "n_frames_used": len(image_records),
        "n_cameras": len(cameras),
        "n_points_3d": len(points3D),
        "mean_track_length": round(mean_track_len, 3),
        "has_world_map": ar_run.has_world_map,
        "has_mesh": ar_run.has_mesh,
        "elapsed_seconds": round(elapsed, 2),
        "ran_at": _utc_now(),
        "run_dir": str(run_dir),
    }
    (meta_dir / "layer4_pose_bridge.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    _seed_run_metadata(run_dir, manifest, new_run_id, summary)

    if verbose:
        print(f"[Layer 4] ✓ done in {elapsed:.1f}s — run_dir = "
              f"{run_dir.relative_to(_REPO_ROOT)}")
        print(f"[Layer 4] Next: train Brush on this run with the existing "
              f"pipeline, e.g.:")
        print(f"    python3 -m pipeline.run_pipeline --dataset-dir "
              f"{run_dir.relative_to(_REPO_ROOT)} --run-id {new_run_id}")

    return summary


def _seed_run_metadata(run_dir: Path, manifest: dict, run_id: str, summary: dict) -> None:
    """Write a minimal run_metadata.json so layers 5/6/7 (and Layer 7's
    AI report) can read consistent provenance fields."""
    seed = {
        "run_id": run_id,
        "schema_version": 1,
        "created_at": _utc_now(),
        "status": "ar_pose_bridge_complete",
        "video_selection": "ar_capture",
        "config": {
            "source": "ar",
            "scene_type": manifest.get("scene_type"),
            "ar_run_id": summary["ar_run_id"],
        },
        "paths": {
            "run_root": str(run_dir),
            "frames_dir": str((run_dir / "images").resolve()),
            "source_images_dir": str((run_dir / "source").resolve()),
            "colmap_sparse": str((run_dir / "sparse" / "0").resolve()),
            "outputs_splat_dir": str((run_dir / "outputs" / "output_ply").resolve()),
            "final_splat": None,
        },
        "stages": {
            "layer4_pose_bridge": summary,
        },
        "errors": None,
    }
    (run_dir / "metadata" / "run_metadata.json").write_text(
        json.dumps(seed, indent=2) + "\n", encoding="utf-8"
    )


def _setup_layer4_log(log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    fh = logging.FileHandler(log_path, mode="a", encoding="utf-8")
    fh.setLevel(logging.INFO)
    fh.setFormatter(logging.Formatter(
        "%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    ))
    log.handlers = [fh]
    log.setLevel(logging.INFO)


# ── CLI ───────────────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(
        description="AR-Layer 4: convert ar_runs/<id>/capture/ → runs/<new_id>/",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--ar-run-dir", type=Path, required=True,
        help="Path to an ar_runs/<id>/ produced by Layer 3.",
    )
    parser.add_argument(
        "--runs-root", type=Path, default=None,
        help="Where to write the new COLMAP-shaped run "
             "(default: <repo>/runs/).",
    )
    parser.add_argument(
        "--copy", action="store_true",
        help="Copy frame JPEGs instead of symlinking.",
    )
    parser.add_argument(
        "--quiet", action="store_true",
        help="Suppress progress prints.",
    )
    args = parser.parse_args()

    try:
        summary = run_layer4(
            args.ar_run_dir,
            runs_root=args.runs_root,
            copy_mode="copy" if args.copy else "symlink",
            verbose=not args.quiet,
        )
    except Exception as e:   # noqa: BLE001
        print(f"[Layer 4] ✗ failed: {e}", file=sys.stderr)
        return 1
    if args.quiet:
        print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
