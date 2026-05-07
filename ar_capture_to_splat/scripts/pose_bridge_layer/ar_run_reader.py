"""Read + validate an `ar_runs/<id>/capture/` directory produced by Layer 3.

Layer 4's pose bridge consumes the AR run via this module so the
COLMAP-conversion code never has to remember manifest field names or
where each sidecar lives.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ARFrameRecord:
    frame_id: int
    timestamp_unix: float
    image_path: str                       # relative to capture/, e.g. "frames/frame_000074.jpg"
    width: int
    height: int
    camera_transform_world: list[list[float]]   # 4×4 row-major, ARKit camera→world
    camera_intrinsics: list[list[float]]        # 3×3 row-major
    tracking_state: str
    captured_high_resolution: bool
    feature_points_path: str | None       # relative to capture/, or None


@dataclass
class ARRun:
    capture_dir: Path
    manifest: dict
    accepted_frames: list[ARFrameRecord]
    has_world_map: bool
    has_mesh: bool


# ── Loaders ────────────────────────────────────────────────────────────────────


def load_ar_run(ar_run_dir: Path) -> ARRun:
    """Parse `ar_run_dir/capture/manifest.json` and pre-filter accepted frames.

    Raises ValueError on any of:
      - manifest missing or unreadable
      - schema_version mismatch (only v1 supported)
      - fewer than 10 accepted frames
      - a required per-frame field missing on an accepted frame
    """
    capture_dir = ar_run_dir / "capture"
    manifest_path = capture_dir / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"manifest.json not found at {manifest_path}")

    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)

    schema = manifest.get("schema_version")
    if schema != 1:
        raise ValueError(f"Unsupported schema_version {schema!r}; expected 1")

    raw_frames = manifest.get("frames") or []
    accepted: list[ARFrameRecord] = []
    for fr in raw_frames:
        if not fr.get("accepted_for_training"):
            continue
        rec = _parse_accepted_frame(fr)
        accepted.append(rec)

    if len(accepted) < 10:
        raise ValueError(
            f"Layer 4 needs at least 10 accepted frames; got {len(accepted)}. "
            "Re-shoot with slower, more deliberate motion or relax the "
            "QualityGate."
        )

    has_world_map = (capture_dir / "world_map.arworldmap").is_file()
    has_mesh = (
        (capture_dir / "scene_mesh.obj").is_file()
        or (capture_dir / "scene_mesh.ply").is_file()
    )

    return ARRun(
        capture_dir=capture_dir,
        manifest=manifest,
        accepted_frames=accepted,
        has_world_map=has_world_map,
        has_mesh=has_mesh,
    )


def _parse_accepted_frame(fr: dict) -> ARFrameRecord:
    required = (
        "frame_id", "timestamp", "image_path",
        "image_width", "image_height",
        "camera_transform_world", "camera_intrinsics",
        "tracking_state",
    )
    for k in required:
        if k not in fr or fr[k] is None:
            raise ValueError(f"accepted frame missing required field {k!r}")
    return ARFrameRecord(
        frame_id=int(fr["frame_id"]),
        timestamp_unix=float(fr["timestamp"]),
        image_path=str(fr["image_path"]),
        width=int(fr["image_width"]),
        height=int(fr["image_height"]),
        camera_transform_world=fr["camera_transform_world"],
        camera_intrinsics=fr["camera_intrinsics"],
        tracking_state=str(fr["tracking_state"]),
        captured_high_resolution=bool(fr.get("captured_high_resolution", False)),
        feature_points_path=fr.get("feature_points_path"),
    )


def feature_point_files_by_frame_id(run: ARRun) -> dict[int, Path]:
    """Map each accepted frame_id → absolute path of its feature_points/*.bin
    (only frames that actually have a feature-points sidecar)."""
    out: dict[int, Path] = {}
    for fr in run.accepted_frames:
        if not fr.feature_points_path:
            continue
        p = run.capture_dir / fr.feature_points_path
        if p.is_file():
            out[fr.frame_id] = p
    return out
