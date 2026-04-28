#!/usr/bin/env python3
"""
Exposure scoring via histogram analysis.

Score is in [0, 1]:
  1.0 = well-exposed (mean brightness in [exposure_min, exposure_max])
  0.0 = severely over- or under-exposed

Internally we measure:
  - mean_brightness: mean pixel value / 255
  - over_exposed_ratio: fraction of pixels > 250
  - under_exposed_ratio: fraction of pixels < 5

A frame is penalised proportionally to how far its mean falls outside the
target window, and also penalised for extreme clipping.
"""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np


def _exposure_stats(img_gray: np.ndarray) -> dict:
    total = img_gray.size
    mean_norm = float(img_gray.mean()) / 255.0
    over = float(np.sum(img_gray > 250)) / total
    under = float(np.sum(img_gray < 5)) / total
    return {"mean_brightness": mean_norm, "over_ratio": over, "under_ratio": under}


def score_exposure(
    image_path: Path,
    *,
    target_min: float = 0.15,
    target_max: float = 0.85,
    clip_penalty_weight: float = 0.5,
) -> float:
    """
    Return exposure quality score in [0, 1].
    1.0 = perfectly exposed, 0.0 = completely blown/dark.
    """
    img = cv2.imread(str(image_path), cv2.IMREAD_GRAYSCALE)
    if img is None:
        return 0.0

    stats = _exposure_stats(img)
    mean = stats["mean_brightness"]

    # Distance from target window [target_min, target_max]
    if target_min <= mean <= target_max:
        window_score = 1.0
    elif mean < target_min:
        window_score = max(0.0, 1.0 - (target_min - mean) / target_min)
    else:
        window_score = max(0.0, 1.0 - (mean - target_max) / (1.0 - target_max))

    # Clipping penalty
    clip_ratio = stats["over_ratio"] + stats["under_ratio"]
    clip_score = max(0.0, 1.0 - clip_penalty_weight * clip_ratio * 10)

    return float(window_score * clip_score)


def score_exposure_batch(
    image_paths: list[Path],
    *,
    target_min: float = 0.15,
    target_max: float = 0.85,
) -> dict[str, float]:
    return {
        p.name: score_exposure(p, target_min=target_min, target_max=target_max)
        for p in image_paths
    }
