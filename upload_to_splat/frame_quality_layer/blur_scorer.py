#!/usr/bin/env python3
"""
Blur scoring via Laplacian variance.

Higher score = sharper frame.
Threshold: frames below `min_blur_score` are rejected.

Rule of thumb: < 50 is very blurry, < 100 blurry, > 200 sharp.
Default threshold: 80.0 (tunable via config/CLI).
"""

from __future__ import annotations

import cv2
import numpy as np
from pathlib import Path


def score_blur(image_path: Path) -> float:
    """
    Return Laplacian variance (sharpness proxy).
    Higher = sharper. Returns 0.0 on read failure.
    """
    img = cv2.imread(str(image_path), cv2.IMREAD_GRAYSCALE)
    if img is None:
        return 0.0
    lap = cv2.Laplacian(img, cv2.CV_64F)
    return float(lap.var())


def score_blur_batch(image_paths: list[Path]) -> dict[str, float]:
    """Return {filename: blur_score} for all paths."""
    return {p.name: score_blur(p) for p in image_paths}
