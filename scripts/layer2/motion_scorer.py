#!/usr/bin/env python3
"""
Motion / viewpoint-change scoring.

For each frame, compute the mean absolute difference (MAD) against the
previous frame in sorted order.

  - Low MAD  → static, near-duplicate of previous (low viewpoint change)
  - High MAD → large jump or motion blur from fast camera movement

We want frames in the "moderate" range: enough change to add new geometry,
not so much that the frame is motion-blurred.

Returns:
  score in [0, 1]:
    0.0 = identical to previous (pure duplicate)
    ~1.0 = large change

The first frame always gets score 1.0 (no previous to compare to).
"""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np


def _resize_for_diff(img: np.ndarray, width: int = 128) -> np.ndarray:
    """Downscale for fast diff. Aspect ratio preserved."""
    h, w = img.shape[:2]
    new_h = max(1, int(h * width / max(w, 1)))
    return cv2.resize(img, (width, new_h), interpolation=cv2.INTER_AREA)


def score_motion_sequence(
    image_paths: list[Path],
) -> dict[str, float]:
    """
    Given a sorted list of image paths, return {filename: motion_score}.
    Motion score = normalised MAD vs previous frame (0 = no change, 1 = max change).
    """
    scores: dict[str, float] = {}
    prev_small: np.ndarray | None = None

    for path in image_paths:
        img = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        if img is None:
            scores[path.name] = 0.0
            continue

        small = _resize_for_diff(img)

        if prev_small is None:
            scores[path.name] = 1.0  # first frame: assume max novelty
        else:
            # Resize to same shape if needed (should match if source is consistent)
            if prev_small.shape != small.shape:
                prev_small = cv2.resize(prev_small, (small.shape[1], small.shape[0]))
            mad = float(np.mean(np.abs(small.astype(np.int32) - prev_small.astype(np.int32))))
            # Normalise: MAD saturates around 50-80 for large scene changes
            scores[path.name] = min(1.0, mad / 60.0)

        prev_small = small

    return scores
