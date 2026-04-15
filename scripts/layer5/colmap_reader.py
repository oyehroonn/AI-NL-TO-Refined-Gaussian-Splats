"""
Minimal COLMAP binary format reader.

Parses cameras.bin, images.bin, points3D.bin exactly as COLMAP writes them.
No external deps beyond stdlib + numpy.

COLMAP world convention: X_cam = R @ X_world + t
  → X_world = R^T @ (X_cam - t)
"""
from __future__ import annotations

import struct
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

# ── Camera model → number of double params ────────────────────────────────────
_MODEL_PARAMS: dict[int, int] = {
    0: 3,   # SIMPLE_PINHOLE  [f, cx, cy]
    1: 4,   # PINHOLE         [fx, fy, cx, cy]
    2: 4,   # SIMPLE_RADIAL   [f, cx, cy, k1]
    3: 5,   # RADIAL          [f, cx, cy, k1, k2]
    4: 8,   # OPENCV          [fx, fy, cx, cy, k1, k2, p1, p2]
    5: 8,   # OPENCV_FISHEYE  [fx, fy, cx, cy, k1, k2, k3, k4]
    6: 12,  # FULL_OPENCV     [fx, fy, cx, cy, k1, k2, p1, p2, k3, k4, k5, k6]
    7: 5,   # FOV             [fx, fy, cx, cy, omega]
    8: 4,   # SIMPLE_RADIAL_FISHEYE [f, cx, cy, k1]
    9: 5,   # RADIAL_FISHEYE  [f, cx, cy, k1, k2]
    10: 12, # THIN_PRISM_FISHEYE [fx, fy, cx, cy, k1, k2, p1, p2, k3, k4, sx1, sy1]
}

_MODEL_NAMES: dict[int, str] = {
    0: "SIMPLE_PINHOLE", 1: "PINHOLE", 2: "SIMPLE_RADIAL", 3: "RADIAL",
    4: "OPENCV", 5: "OPENCV_FISHEYE", 6: "FULL_OPENCV", 7: "FOV",
    8: "SIMPLE_RADIAL_FISHEYE", 9: "RADIAL_FISHEYE", 10: "THIN_PRISM_FISHEYE",
}


@dataclass
class ColmapCamera:
    id: int
    model_id: int
    model_name: str
    width: int
    height: int
    params: tuple  # float params (f/fx/fy/cx/cy/k1/k2/...)

    @property
    def fx(self) -> float:
        return self.params[0]

    @property
    def fy(self) -> float:
        return self.params[0] if self.model_id in (0, 2, 3, 8, 9) else self.params[1]

    @property
    def cx(self) -> float:
        return self.params[1] if self.model_id in (0, 2, 3, 8, 9) else self.params[2]

    @property
    def cy(self) -> float:
        return self.params[2] if self.model_id in (0, 2, 3, 8, 9) else self.params[3]


@dataclass
class ColmapImage:
    id: int
    qvec: tuple         # (qw, qx, qy, qz)
    tvec: tuple         # (tx, ty, tz) — camera origin in world space? No: R @ X_world + t = X_cam
    camera_id: int
    name: str           # filename (may include subpath)
    xys: list           # [(x, y), ...] 2D keypoint coords in image
    point3d_ids: list   # parallel to xys; -1 = unobserved


@dataclass
class ColmapPoint3D:
    id: int
    xyz: tuple   # (x, y, z) world coords
    rgb: tuple   # (r, g, b) uint8


# ── Quaternion → rotation matrix (COLMAP convention) ─────────────────────────

def qvec2rotmat(qvec) -> np.ndarray:
    """COLMAP quaternion (qw, qx, qy, qz) → 3×3 rotation matrix."""
    w, x, y, z = qvec
    return np.array([
        [1 - 2*(y*y + z*z),     2*(x*y - w*z),     2*(x*z + w*y)],
        [    2*(x*y + w*z), 1 - 2*(x*x + z*z),     2*(y*z - w*x)],
        [    2*(x*z - w*y),     2*(y*z + w*x), 1 - 2*(x*x + y*y)],
    ], dtype=np.float64)


# ── Binary readers ────────────────────────────────────────────────────────────

def read_cameras_binary(path: Path) -> dict[int, ColmapCamera]:
    cameras: dict[int, ColmapCamera] = {}
    with open(path, "rb") as f:
        (n,) = struct.unpack("<Q", f.read(8))
        for _ in range(n):
            cam_id, model_id = struct.unpack("<Ii", f.read(8))
            width, height = struct.unpack("<QQ", f.read(16))
            n_params = _MODEL_PARAMS.get(model_id, 0)
            params = struct.unpack(f"<{n_params}d", f.read(8 * n_params))
            model_name = _MODEL_NAMES.get(model_id, f"UNKNOWN_{model_id}")
            cameras[cam_id] = ColmapCamera(cam_id, model_id, model_name, width, height, params)
    return cameras


def read_images_binary(path: Path) -> dict[int, ColmapImage]:
    images: dict[int, ColmapImage] = {}
    with open(path, "rb") as f:
        (n,) = struct.unpack("<Q", f.read(8))
        for _ in range(n):
            (img_id,) = struct.unpack("<I", f.read(4))
            qvec = struct.unpack("<4d", f.read(32))   # qw qx qy qz
            tvec = struct.unpack("<3d", f.read(24))   # tx ty tz
            (cam_id,) = struct.unpack("<I", f.read(4))

            # Null-terminated filename
            name_bytes = b""
            while True:
                c = f.read(1)
                if c == b"\x00":
                    break
                name_bytes += c
            name = name_bytes.decode("utf-8")

            (n_pts,) = struct.unpack("<Q", f.read(8))
            xys: list[tuple[float, float]] = []
            p3d_ids: list[int] = []
            for _ in range(n_pts):
                x, y = struct.unpack("<2d", f.read(16))
                (p3d_id,) = struct.unpack("<q", f.read(8))   # int64
                xys.append((x, y))
                p3d_ids.append(p3d_id)

            images[img_id] = ColmapImage(img_id, qvec, tvec, cam_id, name, xys, p3d_ids)
    return images


def read_points3d_binary(path: Path, max_points: int | None = None) -> dict[int, ColmapPoint3D]:
    """
    Read points3D.bin.  Set max_points to cap memory usage.
    Track data is skipped (we only need xyz + rgb).
    """
    points: dict[int, ColmapPoint3D] = {}
    with open(path, "rb") as f:
        (n,) = struct.unpack("<Q", f.read(8))
        limit = min(n, max_points) if max_points else n
        for i in range(n):
            (pt_id,) = struct.unpack("<Q", f.read(8))
            xyz = struct.unpack("<3d", f.read(24))
            rgb = struct.unpack("<3B", f.read(3))
            struct.unpack("<d", f.read(8))          # error — skip
            (track_len,) = struct.unpack("<Q", f.read(8))
            f.read(track_len * 8)                   # skip track (image_id + point2D_idx pairs)
            if i < limit:
                points[pt_id] = ColmapPoint3D(pt_id, xyz, rgb)
    return points


def read_points3d_count(path: Path) -> int:
    """Fast: read only the first 8 bytes to get the point count."""
    with open(path, "rb") as f:
        data = f.read(8)
    if len(data) < 8:
        return 0
    (n,) = struct.unpack("<Q", data)
    return n


def read_cameras_count(path: Path) -> int:
    with open(path, "rb") as f:
        data = f.read(8)
    if len(data) < 8:
        return 0
    (n,) = struct.unpack("<Q", data)
    return n


def read_images_count(path: Path) -> int:
    with open(path, "rb") as f:
        data = f.read(8)
    if len(data) < 8:
        return 0
    (n,) = struct.unpack("<Q", data)
    return n
