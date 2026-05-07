"""Decode the per-frame feature_points/*.bin files produced by Layer 3.

Format (16-byte LE header + N × 20 byte payload):
  bytes 0..3   : ASCII 'FPTS' magic
  bytes 4..7   : uint32 LE point count
  bytes 8..15  : uint64 LE reserved
  bytes 16..   : count × { float32 x, float32 y, float32 z, uint64 identifier }

The `identifier` is ARKit's persistent feature-point ID that's stable
across frames within a session — exactly what we need to build COLMAP
tracks (one Point3D per ID, observed in every frame where the ID appears).
"""
from __future__ import annotations

import struct
from collections import defaultdict
from pathlib import Path
from statistics import median

# Magic + on-disk record size
_FPTS_MAGIC = b"FPTS"
_HEADER_SIZE = 16
_POINT_RECORD_SIZE = 4 + 4 + 4 + 8   # x, y, z, id


def load_feature_points(bin_path: Path) -> list[tuple[float, float, float, int]]:
    """Return list of (x, y, z, identifier) tuples for one frame's file."""
    data = bin_path.read_bytes()
    if len(data) < _HEADER_SIZE:
        return []
    if data[:4] != _FPTS_MAGIC:
        raise ValueError(
            f"{bin_path}: missing FPTS magic "
            f"(got {data[:4]!r}); not a Layer 3 feature-points file"
        )
    count = struct.unpack("<I", data[4:8])[0]
    expected = _HEADER_SIZE + count * _POINT_RECORD_SIZE
    if len(data) < expected:
        raise ValueError(
            f"{bin_path}: truncated — expected {expected} bytes, got {len(data)}"
        )
    out: list[tuple[float, float, float, int]] = []
    for i in range(count):
        off = _HEADER_SIZE + i * _POINT_RECORD_SIZE
        x, y, z, ident = struct.unpack("<3fQ", data[off:off + _POINT_RECORD_SIZE])
        out.append((x, y, z, ident))
    return out


def aggregate_by_identifier(
    feature_files_by_frame_id: dict[int, Path],
    *,
    min_track_length: int = 2,
) -> dict[int, dict]:
    """Read every frame's FPTS file and aggregate by persistent identifier.

    Returns a dict keyed by ARKit identifier:
      {
        identifier_uint64: {
          "xyz_world": (median_x, median_y, median_z),
          "frames": [frame_id_int, ...],
        }
      }

    Identifiers seen in fewer than `min_track_length` frames are dropped.
    """
    accum: dict[int, dict[str, list]] = defaultdict(
        lambda: {"xs": [], "ys": [], "zs": [], "frames": []}
    )

    for frame_id, path in feature_files_by_frame_id.items():
        try:
            points = load_feature_points(path)
        except Exception:   # noqa: BLE001
            # Treat unreadable file as "no points this frame" — Layer 4
            # never blocks on a single bad bin.
            continue
        for x, y, z, ident in points:
            slot = accum[ident]
            slot["xs"].append(x)
            slot["ys"].append(y)
            slot["zs"].append(z)
            slot["frames"].append(frame_id)

    out: dict[int, dict] = {}
    for ident, slot in accum.items():
        if len(slot["frames"]) < min_track_length:
            continue
        xyz = (
            float(median(slot["xs"])),
            float(median(slot["ys"])),
            float(median(slot["zs"])),
        )
        out[ident] = {"xyz_world": xyz, "frames": list(slot["frames"])}
    return out
