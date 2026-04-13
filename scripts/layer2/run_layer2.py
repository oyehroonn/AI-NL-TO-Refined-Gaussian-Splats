#!/usr/bin/env python3
"""
Layer 2 CLI — frame quality scoring and keyframe selection.

Run standalone against any images/ folder:
  python3 -m scripts.layer2.run_layer2 --images-dir runs/<id>/images

Or called from pipeline/run_pipeline.py as a stage.

Outputs:
  - Rejected frames moved to <images_dir>/../images_rejected/
  - Score report written to <images_dir>/../metadata/layer2_scores.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Allow running as standalone script with: python3 scripts/layer2/run_layer2.py
_HERE = Path(__file__).resolve().parent.parent  # scripts/
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from layer2.frame_selector import run_selection  # noqa: E402


def run_layer2(
    images_dir: Path,
    *,
    blur_threshold: float = 80.0,
    exposure_threshold: float = 0.15,
    hamming_threshold: int = 8,
    motion_floor: float = 0.03,
    min_keep_frames: int = 30,
    verbose: bool = True,
) -> dict:
    """
    Entry point for pipeline integration.

    images_dir: path to the frames folder (e.g. run_dir/images)
    Returns stats dict (also written to metadata/layer2_scores.json).
    """
    images_dir = images_dir.resolve()
    run_dir = images_dir.parent
    rejected_dir = run_dir / "images_rejected"
    meta_dir = run_dir / "metadata"
    meta_dir.mkdir(parents=True, exist_ok=True)

    stats = run_selection(
        images_dir,
        rejected_dir,
        blur_threshold=blur_threshold,
        exposure_threshold=exposure_threshold,
        hamming_threshold=hamming_threshold,
        motion_floor=motion_floor,
        min_keep_frames=min_keep_frames,
        verbose=verbose,
    )

    report_path = meta_dir / "layer2_scores.json"
    report_path.write_text(
        json.dumps(stats, indent=2) + "\n", encoding="utf-8"
    )
    if verbose:
        print(f"[Layer 2] Score report → {report_path}")

    return stats


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Layer 2: score and filter frames before COLMAP."
    )
    parser.add_argument(
        "--images-dir",
        type=Path,
        required=True,
        help="Directory containing extracted frames (e.g. runs/<id>/images).",
    )
    parser.add_argument(
        "--blur-threshold",
        type=float,
        default=80.0,
        help="Minimum Laplacian variance to keep (default: 80). Higher = stricter.",
    )
    parser.add_argument(
        "--exposure-threshold",
        type=float,
        default=0.15,
        help="Minimum exposure score [0,1] to keep (default: 0.15).",
    )
    parser.add_argument(
        "--hamming-threshold",
        type=int,
        default=8,
        help="dHash Hamming distance; frames closer than this to a kept frame are dropped (default: 8).",
    )
    parser.add_argument(
        "--motion-floor",
        type=float,
        default=0.03,
        help="Minimum motion score [0,1] to keep (default: 0.03). Removes still frames.",
    )
    parser.add_argument(
        "--min-keep-frames",
        type=int,
        default=30,
        help="Safety floor: relax thresholds if fewer frames would be kept (default: 30).",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress progress output.",
    )
    args = parser.parse_args()

    stats = run_layer2(
        args.images_dir,
        blur_threshold=args.blur_threshold,
        exposure_threshold=args.exposure_threshold,
        hamming_threshold=args.hamming_threshold,
        motion_floor=args.motion_floor,
        min_keep_frames=args.min_keep_frames,
        verbose=not args.quiet,
    )

    print(
        f"\nLayer 2 complete: {stats['kept']}/{stats['total_input']} frames kept "
        f"({stats['rejected']} rejected)."
    )


if __name__ == "__main__":
    main()
