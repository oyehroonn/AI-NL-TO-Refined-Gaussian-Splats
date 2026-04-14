#!/usr/bin/env python3
"""
Coverage estimator — Layer 3.

Uses the motion_analyzer pair_records to reconstruct the approximate
2D camera trajectory and assess scene coverage.

Key metrics:

  coverage_completeness   [0,1] — fraction of 8 directional sectors covered
  trajectory_type         — "orbital" | "linear" | "stationary" | "erratic"
  uncovered_sectors       — list of direction labels missing from the path
  capture_path_ascii      — ASCII top-down visualisation of trajectory
  loop_closed             — True if camera returned near start (good for COLMAP)
  orbit_score             — how circular the path is (1=perfect orbit, 0=line/point)
  parallax_score          — estimated depth separation from flow divergence
  frame_overlap_score     — estimated fraction of each frame shared with next
                            (should be 0.5–0.85 for good matching)
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np


_SECTOR_LABELS = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"]


def _integrate_trajectory(pair_records: list[dict]) -> np.ndarray:
    """
    Integrate translation vectors into a 2D path.
    Returns (N+1, 2) array of camera positions (arbitrary units).
    """
    positions = [(0.0, 0.0)]
    for rec in pair_records:
        t = rec["translation_px"]
        ang = math.radians(rec["flow_angle_deg"])
        # Camera movement direction = flow direction
        dx = t * math.cos(ang)
        dy = t * math.sin(ang)
        positions.append((positions[-1][0] + dx, positions[-1][1] + dy))
    return np.array(positions, dtype=np.float64)


def _orbit_score(positions: np.ndarray) -> float:
    """
    How circular is the path?
    Method: fit a circle (least-squares) and measure residual / radius.
    Score 1 = perfect circle, 0 = degenerate (line or point).
    """
    if len(positions) < 8:
        return 0.0

    x = positions[:, 0]
    y = positions[:, 1]

    # Fit circle: (x-cx)^2 + (y-cy)^2 = r^2
    # Linearise: 2*cx*x + 2*cy*y + (r^2-cx^2-cy^2) = x^2+y^2
    A = np.column_stack([2 * x, 2 * y, np.ones(len(x))])
    b = x ** 2 + y ** 2
    try:
        res, _, _, _ = np.linalg.lstsq(A, b, rcond=None)
    except Exception:
        return 0.0

    cx, cy, c = res
    r_sq = c + cx ** 2 + cy ** 2
    if r_sq <= 0:
        return 0.0
    r = math.sqrt(r_sq)

    # Residuals
    dists = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    residual_std = float(dists.std())

    if r < 1.0:
        return 0.0

    # Low residual/radius ratio → good circle
    score = max(0.0, 1.0 - (residual_std / r) * 2)
    return round(score, 3)


def _loop_closure(positions: np.ndarray) -> tuple[bool, float]:
    """
    Did camera return near start?
    Returns (closed, return_fraction):
      return_fraction = how close end position is to start, as fraction of max extent.
    """
    if len(positions) < 4:
        return False, 0.0

    start = positions[0]
    end = positions[-1]
    dist_end_to_start = float(np.linalg.norm(end - start))

    # Max pairwise distance (diameter of path)
    extent = float(np.max(np.linalg.norm(positions - positions[0], axis=1)))
    if extent < 1.0:
        return False, 0.0

    fraction = dist_end_to_start / extent
    closed = fraction < 0.25  # came back within 25% of path diameter
    return closed, round(1.0 - fraction, 3)


def _trajectory_type(
    orbit_score: float,
    direction_diversity: float,
    median_trans: float,
    mean_resultant: float,
) -> str:
    """Classify trajectory into a human-readable category."""
    if median_trans < 5.0:
        return "stationary"
    if orbit_score > 0.5 and direction_diversity > 0.6:
        return "orbital"
    if mean_resultant > 0.7:
        return "linear"
    if direction_diversity > 0.4:
        return "partial_orbit"
    return "erratic"


def _ascii_path(positions: np.ndarray, width: int = 40, height: int = 20) -> list[str]:
    """Render camera path as ASCII art top-down view."""
    if len(positions) < 2:
        return ["(no path data)"]

    xs = positions[:, 0]
    ys = positions[:, 1]
    x_range = xs.max() - xs.min()
    y_range = ys.max() - ys.min()

    if x_range < 1e-6 and y_range < 1e-6:
        return ["(stationary — no movement detected)"]

    grid = [[" "] * width for _ in range(height)]

    def to_grid(x, y):
        if x_range > 0:
            gx = int((x - xs.min()) / x_range * (width - 1))
        else:
            gx = width // 2
        if y_range > 0:
            gy = int((y - ys.min()) / y_range * (height - 1))
        else:
            gy = height // 2
        return min(gx, width - 1), min(height - 1 - gy, height - 1)

    for i, (x, y) in enumerate(positions):
        gx, gy = to_grid(x, y)
        if i == 0:
            grid[gy][gx] = "S"  # start
        elif i == len(positions) - 1:
            grid[gy][gx] = "E"  # end
        else:
            if grid[gy][gx] == " ":
                grid[gy][gx] = "·"

    border = "+" + "-" * width + "+"
    lines = [border]
    for row in grid:
        lines.append("|" + "".join(row) + "|")
    lines.append(border)
    lines.append("S=start  E=end  ·=path")
    return lines


def _frame_overlap_score(pair_records: list[dict], img_w: int = 1920, img_h: int = 1080) -> float:
    """
    Estimate overlap fraction between consecutive kept frames.
    Based on translation magnitude: overlap = 1 - (trans_px / img_w).
    Returns mean overlap fraction.
    """
    if not pair_records:
        return 0.0
    overlaps = []
    for r in pair_records:
        t = r["translation_px"]
        # Approximate: horizontal overlap if purely translating
        overlap = max(0.0, min(1.0, 1.0 - t / img_w))
        overlaps.append(overlap)
    return round(float(np.mean(overlaps)), 3)


def _parallax_score(pair_records: list[dict]) -> float:
    """
    Estimate depth separation from FOE distance to image centre.
    FOE very close to centre AND large translation → strong forward motion → parallax present.
    Returns [0,1]: 1 = strong parallax (good for COLMAP triangulation).
    """
    scores = []
    for r in pair_records:
        foe_x = r.get("foe_x")
        foe_y = r.get("foe_y")
        t = r["translation_px"]
        if foe_x is None or foe_y is None or t < 3:
            continue
        foe_dist = math.sqrt(foe_x ** 2 + foe_y ** 2)
        # Strong parallax: FOE near centre + translation > threshold
        # Weak parallax: FOE far from centre (rotational) or tiny translation
        if foe_dist < 0.5:
            s = min(1.0, t / 30.0)
        else:
            s = max(0.0, min(1.0, t / 50.0) * (1.0 - foe_dist / 3.0))
        scores.append(s)
    if not scores:
        return 0.2  # default guess
    return round(float(np.mean(scores)), 3)


def estimate_coverage(motion_data: dict) -> dict:
    """
    Given output of motion_analyzer.analyze_motion_sequence(), produce
    coverage and trajectory analysis.
    """
    pair_records = motion_data.get("pair_records", [])
    direction_diversity = motion_data.get("direction_diversity_score", 0.0)
    sector_counts = motion_data.get("sector_counts", [0] * 8)
    sector_labels = motion_data.get("sector_labels", _SECTOR_LABELS)
    median_trans = motion_data.get("median_translation_px", 0.0)
    mean_resultant = motion_data.get("mean_resultant_length", 0.0)

    if not pair_records:
        return _empty_coverage_result()

    positions = _integrate_trajectory(pair_records)
    orb = _orbit_score(positions)
    loop_closed, loop_fraction = _loop_closure(positions)
    traj_type = _trajectory_type(orb, direction_diversity, median_trans, mean_resultant)
    ascii_lines = _ascii_path(positions)

    uncovered = [
        sector_labels[i] for i, c in enumerate(sector_counts) if c == 0
    ]

    overlap = _frame_overlap_score(pair_records)
    parallax = _parallax_score(pair_records)

    return {
        "trajectory_type": traj_type,
        "orbit_score": orb,
        "loop_closed": loop_closed,
        "loop_closure_fraction": loop_fraction,
        "covered_sectors": [sector_labels[i] for i, c in enumerate(sector_counts) if c > 0],
        "uncovered_sectors": uncovered,
        "n_covered_sectors": sum(1 for c in sector_counts if c > 0),
        "coverage_completeness": round(direction_diversity, 3),
        "frame_overlap_score": overlap,
        "parallax_score": parallax,
        "capture_path_ascii": ascii_lines,
    }


def _empty_coverage_result() -> dict:
    return {
        "trajectory_type": "unknown",
        "orbit_score": 0.0,
        "loop_closed": False,
        "loop_closure_fraction": 0.0,
        "covered_sectors": [],
        "uncovered_sectors": list(_SECTOR_LABELS),
        "n_covered_sectors": 0,
        "coverage_completeness": 0.0,
        "frame_overlap_score": 0.0,
        "parallax_score": 0.0,
        "capture_path_ascii": ["(no data)"],
    }
