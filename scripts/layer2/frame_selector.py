#!/usr/bin/env python3
"""
Frame selector: combines all four scores and decides keep vs. reject.

Selection pipeline (in order):
  1. Blur filter   — reject frames below blur_threshold (Laplacian var)
  2. Exposure filter — reject frames below exposure_threshold (0-1 score)
  3. Duplicate filter — reject near-duplicates (dHash Hamming > hamming_threshold keeps)
  4. Motion floor  — after dedup, reject frames whose motion score < motion_floor
     (catches static runs that slipped past dedup)

Rejected frames are MOVED to images_rejected/ (not deleted).
A JSON report is written to metadata/layer2_scores.json.

Minimum-keep guard: if selection would drop below min_keep_frames,
thresholds are relaxed progressively so COLMAP always has enough frames.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from .blur_scorer import score_blur
from .exposure_scorer import score_exposure
from .motion_scorer import score_motion_sequence
from .duplicate_scorer import select_non_duplicates

IMAGE_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png", ".bmp", ".tiff", ".tif"})


def _collect_images(images_dir: Path) -> list[Path]:
    """Return sorted list of image files in images_dir."""
    paths = [
        p for p in images_dir.iterdir()
        if p.is_file() and p.suffix.lower() in IMAGE_EXTENSIONS
    ]
    return sorted(paths, key=lambda p: p.name)


def run_selection(
    images_dir: Path,
    rejected_dir: Path,
    *,
    blur_threshold: float = 80.0,
    exposure_threshold: float = 0.15,
    hamming_threshold: int = 8,
    motion_floor: float = 0.03,
    min_keep_frames: int = 30,
    verbose: bool = True,
) -> dict:
    """
    Score all frames and move rejected ones to rejected_dir.

    Returns a stats dict suitable for writing to run_metadata.json.
    """
    images_dir = images_dir.resolve()
    rejected_dir = rejected_dir.resolve()
    rejected_dir.mkdir(parents=True, exist_ok=True)

    all_frames = _collect_images(images_dir)
    n_total = len(all_frames)

    if n_total == 0:
        return {"error": "no images found", "kept": 0, "rejected": 0, "total": 0}

    if verbose:
        print(f"\n[Layer 2] Scoring {n_total} frames...")

    # ── 1. Blur scores ──────────────────────────────────────────────────────
    blur_scores: dict[str, float] = {}
    for p in all_frames:
        blur_scores[p.name] = score_blur(p)

    # ── 2. Exposure scores ──────────────────────────────────────────────────
    exposure_scores: dict[str, float] = {}
    for p in all_frames:
        exposure_scores[p.name] = score_exposure(p)

    # ── 3. Motion scores (sequential) ──────────────────────────────────────
    motion_scores = score_motion_sequence(all_frames)

    # ── 4. Duplicate detection ──────────────────────────────────────────────
    non_dup_set, redundancy_scores = select_non_duplicates(
        all_frames, hamming_threshold=hamming_threshold
    )

    # ── Build per-frame records ─────────────────────────────────────────────
    frame_records: list[dict] = []
    for p in all_frames:
        name = p.name
        frame_records.append(
            {
                "name": name,
                "blur": round(blur_scores[name], 3),
                "exposure": round(exposure_scores[name], 3),
                "motion": round(motion_scores[name], 3),
                "redundancy": round(redundancy_scores.get(name, 0.0), 3),
            }
        )

    # ── Apply filters with min-keep guard ──────────────────────────────────
    def _apply_filters(
        bt: float, et: float, ht: int, mf: float
    ) -> tuple[set[str], set[str]]:
        # Re-run duplicate detection with possibly relaxed threshold
        nd_set, _ = select_non_duplicates(all_frames, hamming_threshold=ht)
        keep: set[str] = set()
        reject: set[str] = set()
        for p in all_frames:
            name = p.name
            reasons = []
            if blur_scores[name] < bt:
                reasons.append("blur")
            if exposure_scores[name] < et:
                reasons.append("exposure")
            if name not in nd_set:
                reasons.append("duplicate")
            elif motion_scores[name] < mf:
                reasons.append("static")
            if reasons:
                reject.add(name)
            else:
                keep.add(name)
        return keep, reject

    keep_set, reject_set = _apply_filters(
        blur_threshold, exposure_threshold, hamming_threshold, motion_floor
    )

    # Progressive relaxation if too few kept
    relaxation_steps = [
        # (blur_t, exposure_t, hamming_t, motion_floor)
        (blur_threshold * 0.5, exposure_threshold * 0.5, hamming_threshold // 2, motion_floor * 0.5),
        (0.0, 0.0, 0, 0.0),  # keep everything
    ]
    relaxed = False
    for bt, et, ht, mf in relaxation_steps:
        if len(keep_set) >= min_keep_frames:
            break
        if verbose:
            print(
                f"[Layer 2] Only {len(keep_set)} frames pass; relaxing thresholds "
                f"(blur>={bt:.0f}, exp>={et:.2f}, hamming>{ht}, motion>={mf:.2f})"
            )
        keep_set, reject_set = _apply_filters(bt, et, ht, mf)
        relaxed = True

    # ── Move rejected frames ────────────────────────────────────────────────
    reject_reasons: dict[str, list[str]] = {}
    for p in all_frames:
        name = p.name
        if name in reject_set:
            reasons = []
            if blur_scores[name] < blur_threshold:
                reasons.append("blur")
            if exposure_scores[name] < exposure_threshold:
                reasons.append("exposure")
            if redundancy_scores.get(name, 0.0) > (1.0 - hamming_threshold / 64.0):
                reasons.append("duplicate")
            if motion_scores[name] < motion_floor:
                reasons.append("static")
            reject_reasons[name] = reasons or ["threshold_relaxation_kept_anyway"]
            shutil.move(str(p), str(rejected_dir / name))

    n_kept = len(keep_set)
    n_rejected = len(reject_set)

    if verbose:
        print(
            f"[Layer 2] Done: kept {n_kept}, rejected {n_rejected} "
            f"(blur={sum(1 for r in reject_reasons.values() if 'blur' in r)}, "
            f"exposure={sum(1 for r in reject_reasons.values() if 'exposure' in r)}, "
            f"duplicate={sum(1 for r in reject_reasons.values() if 'duplicate' in r)}, "
            f"static={sum(1 for r in reject_reasons.values() if 'static' in r)})"
        )

    return {
        "total_input": n_total,
        "kept": n_kept,
        "rejected": n_rejected,
        "thresholds_relaxed": relaxed,
        "thresholds": {
            "blur": blur_threshold,
            "exposure": exposure_threshold,
            "hamming": hamming_threshold,
            "motion_floor": motion_floor,
            "min_keep_frames": min_keep_frames,
        },
        "reject_reasons": {
            k: v for k, v in reject_reasons.items()
        },
        "frame_scores": frame_records,
    }
