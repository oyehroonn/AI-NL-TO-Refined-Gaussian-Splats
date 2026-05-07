"""ARKit pose ↔ COLMAP pose math.

ARKit camera frame:    +X right, +Y up,    -Z forward (right-handed)
COLMAP camera frame:   +X right, +Y down,  +Z forward (right-handed)

A point in the ARKit camera frame relates to the COLMAP camera frame by
a flip on the Y and Z axes:

    P_arkit_cam = diag(1, -1, -1) · P_colmap_cam

ARKit's `camera.transform` is **camera→world**. COLMAP's `images.bin`
needs **world→camera** as a quaternion + translation. The conversion is:

    T_colmap_c2w = T_arkit_c2w · diag(1, -1, -1, 1)
    T_colmap_w2c = inv(T_colmap_c2w)
"""
from __future__ import annotations

import math


# ── 4×4 matrix utilities (no numpy dependency) ────────────────────────────────


Mat4 = list[list[float]]


def _identity() -> Mat4:
    return [
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ]


def _matmul4(a: Mat4, b: Mat4) -> Mat4:
    out = [[0.0] * 4 for _ in range(4)]
    for i in range(4):
        for j in range(4):
            s = 0.0
            for k in range(4):
                s += a[i][k] * b[k][j]
            out[i][j] = s
    return out


def _invert_rigid(m: Mat4) -> Mat4:
    """Invert a 4×4 that's a pure rigid transform (rotation + translation).

    For rigid: inv(R | t) = (R.T | -R.T · t).
    """
    R = [[m[i][j] for j in range(3)] for i in range(3)]
    t = [m[i][3] for i in range(3)]
    Rt = [[R[j][i] for j in range(3)] for i in range(3)]   # transpose
    minus_Rt_t = [
        -(Rt[0][0] * t[0] + Rt[0][1] * t[1] + Rt[0][2] * t[2]),
        -(Rt[1][0] * t[0] + Rt[1][1] * t[1] + Rt[1][2] * t[2]),
        -(Rt[2][0] * t[0] + Rt[2][1] * t[1] + Rt[2][2] * t[2]),
    ]
    inv = _identity()
    for i in range(3):
        for j in range(3):
            inv[i][j] = Rt[i][j]
        inv[i][3] = minus_Rt_t[i]
    return inv


def _flip_y_z() -> Mat4:
    return [
        [1.0,  0.0,  0.0, 0.0],
        [0.0, -1.0,  0.0, 0.0],
        [0.0,  0.0, -1.0, 0.0],
        [0.0,  0.0,  0.0, 1.0],
    ]


# ── Public conversion ─────────────────────────────────────────────────────────


def arkit_c2w_to_colmap_w2c(arkit_c2w_rows: list[list[float]]) -> tuple[
    tuple[float, float, float, float],   # qvec (qw, qx, qy, qz)
    tuple[float, float, float],          # tvec (tx, ty, tz)
    Mat4,                                # full COLMAP world→camera 4×4
]:
    """Convert ARKit camera→world (4×4 row-major) to COLMAP world→camera
    (qvec + tvec). Returns the full matrix too for downstream re-projection.
    """
    if (len(arkit_c2w_rows) != 4
            or any(len(r) != 4 for r in arkit_c2w_rows)):
        raise ValueError("Expected 4x4 row-major matrix")
    arkit_c2w: Mat4 = [[float(v) for v in row] for row in arkit_c2w_rows]
    colmap_c2w = _matmul4(arkit_c2w, _flip_y_z())
    colmap_w2c = _invert_rigid(colmap_c2w)

    # Extract rotation + translation
    R = [[colmap_w2c[i][j] for j in range(3)] for i in range(3)]
    t = (colmap_w2c[0][3], colmap_w2c[1][3], colmap_w2c[2][3])
    qvec = _rotation_matrix_to_quaternion(R)
    return qvec, t, colmap_w2c


def _rotation_matrix_to_quaternion(R: list[list[float]]) -> tuple[
    float, float, float, float
]:
    """3×3 rotation matrix → (qw, qx, qy, qz). Uses Shepperd's method
    (numerically stable across all rotations). COLMAP convention.
    """
    trace = R[0][0] + R[1][1] + R[2][2]
    if trace > 0.0:
        s = math.sqrt(trace + 1.0) * 2.0
        qw = 0.25 * s
        qx = (R[2][1] - R[1][2]) / s
        qy = (R[0][2] - R[2][0]) / s
        qz = (R[1][0] - R[0][1]) / s
    elif R[0][0] > R[1][1] and R[0][0] > R[2][2]:
        s = math.sqrt(1.0 + R[0][0] - R[1][1] - R[2][2]) * 2.0
        qw = (R[2][1] - R[1][2]) / s
        qx = 0.25 * s
        qy = (R[0][1] + R[1][0]) / s
        qz = (R[0][2] + R[2][0]) / s
    elif R[1][1] > R[2][2]:
        s = math.sqrt(1.0 + R[1][1] - R[0][0] - R[2][2]) * 2.0
        qw = (R[0][2] - R[2][0]) / s
        qx = (R[0][1] + R[1][0]) / s
        qy = 0.25 * s
        qz = (R[1][2] + R[2][1]) / s
    else:
        s = math.sqrt(1.0 + R[2][2] - R[0][0] - R[1][1]) * 2.0
        qw = (R[1][0] - R[0][1]) / s
        qx = (R[0][2] + R[2][0]) / s
        qy = (R[1][2] + R[2][1]) / s
        qz = 0.25 * s
    return (qw, qx, qy, qz)


# ── Re-projection helper ──────────────────────────────────────────────────────


def project_world_point_to_pixel(
    point_world: tuple[float, float, float],
    colmap_w2c: Mat4,
    intrinsics: list[list[float]],   # 3×3 row-major (fx,0,cx;0,fy,cy;0,0,1)
    width: int,
    height: int,
) -> tuple[float, float] | None:
    """Project a world-space 3D point through a COLMAP world→camera transform
    and a 3×3 intrinsics matrix. Returns (u, v) in pixel coords, or None
    when the point is behind the camera or projects outside the image.
    """
    # World → camera (homogeneous)
    px, py, pz = point_world
    cx_cam = colmap_w2c[0][0] * px + colmap_w2c[0][1] * py + colmap_w2c[0][2] * pz + colmap_w2c[0][3]
    cy_cam = colmap_w2c[1][0] * px + colmap_w2c[1][1] * py + colmap_w2c[1][2] * pz + colmap_w2c[1][3]
    cz_cam = colmap_w2c[2][0] * px + colmap_w2c[2][1] * py + colmap_w2c[2][2] * pz + colmap_w2c[2][3]
    if cz_cam <= 1e-6:
        return None
    fx = intrinsics[0][0]
    fy = intrinsics[1][1]
    cx = intrinsics[0][2]
    cy = intrinsics[1][2]
    u = fx * (cx_cam / cz_cam) + cx
    v = fy * (cy_cam / cz_cam) + cy
    if u < 0 or v < 0 or u >= width or v >= height:
        return None
    return (u, v)
