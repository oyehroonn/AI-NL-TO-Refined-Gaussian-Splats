"""
Layer 6 — PLY Analyzer.

Parses a 3D Gaussian Splatting PLY file and extracts quality metrics.
No external deps beyond numpy + stdlib.

3DGS PLY conventions (Brush / standard 3DGS format):
  opacity  : raw logit  → actual = sigmoid(opacity)
  scale_i  : log scale  → actual = exp(scale_i)
  rot_*    : unit quaternion (no activation needed)
  f_dc_*   : SH degree-0 coefficients (DC colour)
"""
from __future__ import annotations

from pathlib import Path

import numpy as np


# ── PLY binary reader ─────────────────────────────────────────────────────────

_PLY_DTYPES: dict[str, str] = {
    "float":   "f4", "float32": "f4",
    "double":  "f8", "float64": "f8",
    "uchar":   "u1", "uint8":   "u1",
    "char":    "i1", "int8":    "i1",
    "short":   "i2", "int16":   "i2",
    "ushort":  "u2", "uint16":  "u2",
    "int":     "i4", "int32":   "i4",
    "uint":    "u4", "uint32":  "u4",
}


def _read_ply_header(f) -> tuple[int, list[tuple[str, str]], str]:
    """
    Read PLY header from an open binary file.
    Returns (n_vertices, [(prop_name, numpy_dtype), ...], format_str).
    Raises ValueError on invalid PLY.
    """
    magic = f.readline().strip()
    if magic != b"ply":
        raise ValueError(f"Not a PLY file (magic={magic!r})")

    n_vertices = 0
    properties: list[tuple[str, str]] = []
    fmt = "ascii"
    in_vertex = False

    while True:
        raw = f.readline()
        if not raw:
            raise ValueError("Truncated PLY header (missing end_header)")
        line   = raw.strip().decode("ascii", errors="replace")
        tokens = line.split()
        if not tokens:
            continue
        kw = tokens[0]

        if kw == "end_header":
            break
        elif kw == "format":
            fmt = tokens[1]
        elif kw == "element":
            in_vertex = (tokens[1] == "vertex")
            if in_vertex:
                n_vertices = int(tokens[2])
        elif kw == "property" and in_vertex:
            if tokens[1] == "list":
                pass  # face data — skip
            else:
                dtype_str = _PLY_DTYPES.get(tokens[1], "f4")
                properties.append((tokens[2], dtype_str))

    return n_vertices, properties, fmt


def load_gaussians(ply_path: Path) -> np.ndarray | None:
    """
    Load all Gaussians from a 3DGS PLY file into a structured numpy array.
    Returns None if file is missing, empty, or not binary format.
    """
    if not ply_path.is_file():
        return None

    with open(ply_path, "rb") as f:
        n_verts, props, fmt = _read_ply_header(f)
        if n_verts == 0 or not props:
            return None
        if fmt not in ("binary_little_endian", "binary_big_endian"):
            return None   # ASCII PLY — not practical for 100k+ Gaussians

        dtype = np.dtype([(name, dt) for name, dt in props])
        raw   = f.read(n_verts * dtype.itemsize)

    byte_order = "<" if fmt == "binary_little_endian" else ">"
    return np.frombuffer(raw, dtype=dtype.newbyteorder(byte_order))


# ── Activation helpers ────────────────────────────────────────────────────────

def _sigmoid(x: np.ndarray) -> np.ndarray:
    """Numerically stable element-wise sigmoid."""
    return np.where(
        x >= 0,
        1.0 / (1.0 + np.exp(-x)),
        np.exp(x) / (1.0 + np.exp(x)),
    )


# ── Main analysis ─────────────────────────────────────────────────────────────

def analyze_ply(ply_path: Path) -> dict:
    """
    Full statistical analysis of a 3DGS PLY file.

    Returns a dict containing:
      ok, total_gaussians, centroid, bounding_box, scene_diameter,
      floater_stats, scale_stats, opacity_stats, density_map.

    Keys prefixed with _ (e.g. _positions, _floater_mask) are numpy arrays
    kept for downstream analyzers and are stripped before JSON serialisation.
    """
    result: dict = {"ply_path": str(ply_path), "ok": False, "error": None}

    data = load_gaussians(ply_path)
    if data is None:
        result["error"] = "PLY file missing or empty"
        return result

    n = len(data)
    result["total_gaussians"] = n

    # ── Positions ─────────────────────────────────────────────────────────────
    if not all(k in data.dtype.names for k in ("x", "y", "z")):
        result["error"] = "PLY missing x/y/z position fields"
        return result

    pos = np.stack(
        [data["x"].astype(np.float32),
         data["y"].astype(np.float32),
         data["z"].astype(np.float32)],
        axis=1,
    )  # (N, 3)

    centroid  = pos.mean(axis=0)
    pos_std   = pos.std(axis=0)
    bb_min    = pos.min(axis=0)
    bb_max    = pos.max(axis=0)
    scene_dia = float(np.linalg.norm(bb_max - bb_min))

    result["centroid"]       = centroid.tolist()
    result["positions_std"]  = pos_std.tolist()
    result["bounding_box"]   = {"min": bb_min.tolist(), "max": bb_max.tolist()}
    result["scene_diameter"] = round(scene_dia, 4)

    # ── Floater detection (IQR method) ────────────────────────────────────────
    dists = np.linalg.norm(pos - centroid, axis=1)   # (N,)
    q1, q3 = np.percentile(dists, [25, 75])
    iqr    = q3 - q1
    floater_thresh = q3 + 3.0 * iqr
    floater_mask   = dists > floater_thresh
    n_floaters     = int(floater_mask.sum())

    result["floater_stats"] = {
        "count":              n_floaters,
        "fraction":           round(float(n_floaters) / n, 4),
        "distance_threshold": round(float(floater_thresh), 4),
        "distance_q1":        round(float(q1), 4),
        "distance_q3":        round(float(q3), 4),
        "distance_iqr":       round(float(iqr), 4),
        "distance_p99":       round(float(np.percentile(dists, 99)), 4),
    }

    # ── Scale analysis ─────────────────────────────────────────────────────────
    if all(k in data.dtype.names for k in ("scale_0", "scale_1", "scale_2")):
        s0 = np.exp(data["scale_0"].astype(np.float32))
        s1 = np.exp(data["scale_1"].astype(np.float32))
        s2 = np.exp(data["scale_2"].astype(np.float32))

        max_scale      = np.maximum(np.maximum(s0, s1), s2)   # largest axis
        geo_mean_scale = (s0 * s1 * s2) ** (1.0 / 3.0)        # volume proxy
        rel_max        = max_scale / max(scene_dia, 1e-6)      # relative to scene

        result["scale_stats"] = {
            "max_scale": {
                "mean": round(float(max_scale.mean()), 6),
                "p50":  round(float(np.percentile(max_scale, 50)), 6),
                "p95":  round(float(np.percentile(max_scale, 95)), 6),
                "p99":  round(float(np.percentile(max_scale, 99)), 6),
                "max":  round(float(max_scale.max()), 6),
            },
            "geo_mean_scale": {
                "mean": round(float(geo_mean_scale.mean()), 6),
                "p50":  round(float(np.percentile(geo_mean_scale, 50)), 6),
                "p95":  round(float(np.percentile(geo_mean_scale, 95)), 6),
            },
            "relative_to_scene": {
                "mean_max_scale_frac": round(float(rel_max.mean()), 6),
                "p95_max_scale_frac":  round(float(np.percentile(rel_max, 95)), 6),
            },
            "fraction_oversized": round(float((rel_max > 0.05).sum()) / n, 4),
        }
        result["_max_scales"] = max_scale
    else:
        result["scale_stats"]  = None
        result["_max_scales"]  = None

    # ── Opacity analysis ──────────────────────────────────────────────────────
    if "opacity" in data.dtype.names:
        raw_op  = data["opacity"].astype(np.float32)
        opacity = _sigmoid(raw_op)

        result["opacity_stats"] = {
            "mean":               round(float(opacity.mean()), 4),
            "p50":                round(float(np.percentile(opacity, 50)), 4),
            "fraction_below_01":  round(float((opacity < 0.1).sum()) / n, 4),
            "fraction_below_03":  round(float((opacity < 0.3).sum()) / n, 4),
            "fraction_above_09":  round(float((opacity > 0.9).sum()) / n, 4),
        }
    else:
        result["opacity_stats"] = None

    # ── Spatial density voxel grid ─────────────────────────────────────────────
    core_pos = pos[~floater_mask]
    if len(core_pos) > 0:
        bb_c  = core_pos.min(axis=0)
        bb_cx = core_pos.max(axis=0)
        span  = np.where((bb_cx - bb_c) < 1e-6, 1e-6, bb_cx - bb_c)

        GRID = 16   # 16³ = 4 096 voxels — fast and informative
        vidx = np.floor(
            (core_pos - bb_c) / span * (GRID - 1e-6)
        ).astype(np.int32).clip(0, GRID - 1)

        flat = (vidx[:, 0] * GRID * GRID + vidx[:, 1] * GRID + vidx[:, 2])
        unique_cells, counts = np.unique(flat, return_counts=True)

        total_cells  = GRID ** 3
        occupied     = int(len(unique_cells))
        empty_frac   = round(float(total_cells - occupied) / total_cells, 4)

        top_idx = np.argsort(counts)[-5:][::-1]
        result["density_map"] = {
            "grid_size":            GRID,
            "total_voxels":         total_cells,
            "occupied_voxels":      occupied,
            "empty_voxel_fraction": empty_frac,
            "top_dense_voxels": [
                {
                    "flat_idx": int(unique_cells[i]),
                    "count":    int(counts[i]),
                    "xi": int(unique_cells[i] // (GRID * GRID)),
                    "yi": int((unique_cells[i] // GRID) % GRID),
                    "zi": int(unique_cells[i] % GRID),
                }
                for i in top_idx
            ],
        }
    else:
        result["density_map"] = None

    # Internal arrays for downstream analyzers (stripped before JSON write)
    result["_positions"]    = pos
    result["_floater_mask"] = floater_mask

    result["ok"] = True
    return result
