"""Binary writers for COLMAP's `cameras.bin`, `images.bin`, `points3D.bin`.

Format reference (model values + struct layouts) follows the COLMAP source
in `src/colmap/scene/reconstruction.cc`:
  cameras.bin   — uint64 num_cameras + per-camera (uint32 id, int32 model_id,
                  uint64 width, uint64 height, double[K] params)
  images.bin    — uint64 num_images + per-image (uint32 id,
                  double[4] qvec(qw,qx,qy,qz), double[3] tvec(tx,ty,tz),
                  uint32 camera_id, char[] name (NULL-terminated),
                  uint64 num_points2D, per-point (double x, double y,
                  uint64 point3D_id))
  points3D.bin  — uint64 num_points + per-point (uint64 id, double[3] xyz,
                  uint8[3] rgb, double error, uint64 track_length,
                  per-track-entry (uint32 image_id, uint32 point2D_idx))

We use COLMAP camera model **PINHOLE** (id=1, params: fx, fy, cx, cy)
because ARKit's camera.intrinsics is already rectified (no distortion).
"""
from __future__ import annotations

import struct
from dataclasses import dataclass, field
from pathlib import Path

# ── Camera model IDs (COLMAP: src/colmap/sensor/models.h) ─────────────────────
CAMERA_MODEL_PINHOLE = 1   # params: fx, fy, cx, cy   (4 doubles)
CAMERA_MODEL_NUM_PARAMS = {CAMERA_MODEL_PINHOLE: 4}


# ── In-memory record types ────────────────────────────────────────────────────


@dataclass
class CameraRecord:
    camera_id: int
    model_id: int
    width: int
    height: int
    params: list[float]   # length matches CAMERA_MODEL_NUM_PARAMS[model_id]


@dataclass
class ImagePoint2D:
    x: float
    y: float
    point3D_id: int   # 0 if not associated with a 3D point


@dataclass
class ImageRecord:
    image_id: int
    qvec: tuple[float, float, float, float]   # (qw, qx, qy, qz) — world→camera
    tvec: tuple[float, float, float]          # (tx, ty, tz)     — world→camera
    camera_id: int
    name: str                                 # filename (no path)
    points2D: list[ImagePoint2D] = field(default_factory=list)


@dataclass
class TrackEntry:
    image_id: int
    point2D_idx: int   # 0-based index into ImageRecord.points2D


@dataclass
class Point3DRecord:
    point3D_id: int
    xyz: tuple[float, float, float]
    rgb: tuple[int, int, int]   # 0..255 each
    error: float
    track: list[TrackEntry] = field(default_factory=list)


# ── Writers ───────────────────────────────────────────────────────────────────


def write_cameras_bin(path: Path, cameras: list[CameraRecord]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(cameras)))
        for cam in cameras:
            n_params = CAMERA_MODEL_NUM_PARAMS.get(cam.model_id)
            if n_params is None:
                raise ValueError(f"Unsupported camera model id {cam.model_id}")
            if len(cam.params) != n_params:
                raise ValueError(
                    f"Camera {cam.camera_id}: model {cam.model_id} expects "
                    f"{n_params} params, got {len(cam.params)}"
                )
            f.write(struct.pack(
                "<IiQQ",
                cam.camera_id,
                cam.model_id,
                cam.width,
                cam.height,
            ))
            f.write(struct.pack(f"<{n_params}d", *cam.params))


def write_images_bin(path: Path, images: list[ImageRecord]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(images)))
        for img in images:
            f.write(struct.pack(
                "<I 4d 3d I",
                img.image_id,
                img.qvec[0], img.qvec[1], img.qvec[2], img.qvec[3],
                img.tvec[0], img.tvec[1], img.tvec[2],
                img.camera_id,
            ))
            # name — NUL-terminated UTF-8 bytes
            name_bytes = img.name.encode("utf-8") + b"\x00"
            f.write(name_bytes)
            # points2D — uint64 count then (double x, double y, uint64 pt3D_id)
            f.write(struct.pack("<Q", len(img.points2D)))
            for p in img.points2D:
                f.write(struct.pack("<2dQ", p.x, p.y, p.point3D_id))


def write_points3D_bin(path: Path, points: list[Point3DRecord]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(points)))
        for pt in points:
            f.write(struct.pack(
                "<Q 3d 3B d Q",
                pt.point3D_id,
                pt.xyz[0], pt.xyz[1], pt.xyz[2],
                pt.rgb[0], pt.rgb[1], pt.rgb[2],
                pt.error,
                len(pt.track),
            ))
            for tr in pt.track:
                f.write(struct.pack("<II", tr.image_id, tr.point2D_idx))
