#!/usr/bin/env python3
"""
Lighting analyzer — Layer 3.

Per-frame measurements in CIE LAB + RGB channels:

  L_mean       — perceptual lightness (0-100)
  L_std        — intra-frame contrast
  R_G_ratio    — red/green balance (proxy for color temperature)
  B_G_ratio    — blue/green balance (proxy for color temperature)

Aggregate across frames:
  brightness_cv       — coefficient of variation of L_mean across frames.
                        >0.15 → auto-exposure firing a lot.
  color_temp_drift    — std of (R_G - mean_R_G). Large = white balance shifting.
  n_exposure_jumps    — frames where |ΔL| > threshold (sudden AE lock/unlock).
  n_dark_frames       — frames where L_mean < 30
  n_overexposed       — frames where L_mean > 88
  lighting_stability  — composite [0,1], 1=perfectly stable

These metrics feed into:
  - Issue: UNSTABLE_LIGHTING
  - Issue: WHITE_BALANCE_DRIFT
  - Issue: TOO_DARK / TOO_BRIGHT
"""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np


_SMALL_W = 320
_JUMP_THRESHOLD_L = 8.0   # ΔL that constitutes an exposure jump (LAB units)


def _load_lab_small(path: Path) -> np.ndarray | None:
    bgr = cv2.imread(str(path))
    if bgr is None:
        return None
    h, w = bgr.shape[:2]
    if w > _SMALL_W:
        scale = _SMALL_W / w
        bgr = cv2.resize(bgr, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    # LAB: L in [0,100], A in [-128,127], B in [-128,127]
    lab[:, :, 0] *= 100.0 / 255.0
    return lab


def _rgb_ratios(path: Path) -> tuple[float, float]:
    """Return (R/G, B/G) for white-balance tracking. Small image for speed."""
    bgr = cv2.imread(str(path))
    if bgr is None:
        return 1.0, 1.0
    h, w = bgr.shape[:2]
    if w > _SMALL_W:
        scale = _SMALL_W / w
        bgr = cv2.resize(bgr, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    b = bgr[:, :, 0].astype(float).mean()
    g = bgr[:, :, 1].astype(float).mean()
    r = bgr[:, :, 2].astype(float).mean()
    g = max(g, 1.0)
    return round(r / g, 4), round(b / g, 4)


def analyze_lighting(image_paths: list[Path]) -> dict:
    """Analyze per-frame and aggregate lighting properties."""
    if not image_paths:
        return _empty_lighting_result()

    frame_data: list[dict] = []

    for path in image_paths:
        lab = _load_lab_small(path)
        if lab is None:
            continue
        L = lab[:, :, 0]
        rg, bg = _rgb_ratios(path)
        frame_data.append(
            {
                "name": path.name,
                "L_mean": round(float(L.mean()), 2),
                "L_std": round(float(L.std()), 2),
                "R_G_ratio": rg,
                "B_G_ratio": bg,
            }
        )

    if not frame_data:
        return _empty_lighting_result()

    L_means = np.array([f["L_mean"] for f in frame_data])
    RG = np.array([f["R_G_ratio"] for f in frame_data])
    BG = np.array([f["B_G_ratio"] for f in frame_data])

    # Coefficient of variation of brightness
    brightness_cv = float(L_means.std() / max(L_means.mean(), 1e-3))

    # Color temperature drift: std of RG ratio
    color_temp_drift = float(RG.std())

    # Exposure jumps: |ΔL| > threshold between consecutive frames
    delta_L = np.abs(np.diff(L_means))
    n_jumps = int(np.sum(delta_L > _JUMP_THRESHOLD_L))
    jump_frame_indices = [int(i + 1) for i, d in enumerate(delta_L) if d > _JUMP_THRESHOLD_L]
    jump_frame_names = [frame_data[i]["name"] for i in jump_frame_indices if i < len(frame_data)]

    # Dark / overexposed frame counts
    n_dark = int(np.sum(L_means < 30))
    n_over = int(np.sum(L_means > 88))

    # Lighting stability composite score [0,1]
    # Penalise high CV, high drift, many jumps
    cv_score = max(0.0, 1.0 - brightness_cv / 0.3)
    drift_score = max(0.0, 1.0 - color_temp_drift / 0.3)
    jump_score = max(0.0, 1.0 - n_jumps / max(len(frame_data) * 0.2, 1))
    stability = round((cv_score + drift_score + jump_score) / 3.0, 3)

    return {
        "n_frames": len(frame_data),
        "brightness": {
            "mean_L": round(float(L_means.mean()), 2),
            "std_L": round(float(L_means.std()), 2),
            "min_L": round(float(L_means.min()), 2),
            "max_L": round(float(L_means.max()), 2),
            "cv": round(brightness_cv, 4),
        },
        "color_temperature": {
            "mean_RG": round(float(RG.mean()), 4),
            "std_RG": round(float(RG.std()), 4),
            "mean_BG": round(float(BG.mean()), 4),
            "std_BG": round(float(BG.std()), 4),
            "drift_score": round(color_temp_drift, 4),
        },
        "exposure_jumps": {
            "count": n_jumps,
            "fraction_of_frames": round(n_jumps / max(len(frame_data), 1), 3),
            "jump_frame_names": jump_frame_names,
        },
        "n_dark_frames": n_dark,
        "n_overexposed_frames": n_over,
        "lighting_stability_score": stability,
        "frame_data": frame_data,
    }


def _empty_lighting_result() -> dict:
    return {
        "n_frames": 0,
        "brightness": {},
        "color_temperature": {},
        "exposure_jumps": {"count": 0, "fraction_of_frames": 0.0, "jump_frame_names": []},
        "n_dark_frames": 0,
        "n_overexposed_frames": 0,
        "lighting_stability_score": 1.0,
        "frame_data": [],
    }
