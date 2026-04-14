#!/usr/bin/env python3
"""
Layer 4 CLI — monocular depth map generation.

Run standalone:
  python3 -m scripts.layer4.run_layer4 --images-dir runs/<id>/images

Or called by pipeline/run_pipeline.py between Layer 3 and COLMAP.

Produces:
  runs/<id>/dpt/<stem>.png    — one uint8 depth PNG per frame
  metadata/layer4_depth.json  — stats (model, device, timings)

Brush discovers the dpt/ folder automatically and uses the depth maps for:
  • Dense Gaussian initialisation (vs sparse COLMAP points only)
  • Per-frame depth supervision loss during training
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from layer4.depth_estimator import generate_depth_maps  # noqa: E402


def run_layer4(
    images_dir: Path,
    *,
    model_type: str = "DPT_Large",
    verbose: bool = True,
    skip_existing: bool = True,
) -> dict:
    """
    Pipeline integration entry point.

    images_dir  : path to the (layer2-filtered) frames — e.g. run_dir/images
    model_type  : see depth_estimator.py for options
    Returns stats dict (also written to metadata/layer4_depth.json).
    """
    images_dir = images_dir.resolve()
    run_dir    = images_dir.parent
    dpt_dir    = run_dir / "dpt"
    meta_dir   = run_dir / "metadata"
    meta_dir.mkdir(parents=True, exist_ok=True)

    stats = generate_depth_maps(
        images_dir,
        dpt_dir,
        model_type=model_type,
        verbose=verbose,
        skip_existing=skip_existing,
    )

    report_path = meta_dir / "layer4_depth.json"
    report_path.write_text(json.dumps(stats, indent=2) + "\n", encoding="utf-8")
    if verbose:
        print(f"[Layer 4] Depth report → {report_path}")

    return stats


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Layer 4: generate monocular depth maps (dpt/ folder) for Brush."
    )
    parser.add_argument(
        "--images-dir",
        type=Path,
        required=True,
        help="Directory of filtered frames (e.g. runs/<id>/images).",
    )
    parser.add_argument(
        "--model",
        default="DPT_Large",
        choices=["DPT_Large", "DPT_Hybrid", "MiDaS_small", "depth_anything_v2_small"],
        help=(
            "Depth model. DPT_Large matches test_dataset format exactly (default). "
            "DPT_Hybrid is faster at ~80%% quality. MiDaS_small is CPU-viable. "
            "depth_anything_v2_small is newest SOTA via transformers."
        ),
    )
    parser.add_argument(
        "--no-skip-existing",
        action="store_true",
        help="Re-generate depth maps even if they already exist.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress per-frame progress output.",
    )
    args = parser.parse_args()

    stats = run_layer4(
        args.images_dir,
        model_type=args.model,
        verbose=not args.quiet,
        skip_existing=not args.no_skip_existing,
    )

    if "error" in stats:
        print(f"\n[Layer 4] ERROR: {stats['error']}", file=sys.stderr)
        sys.exit(1)

    print(
        f"\nLayer 4 complete: {stats['n_processed']} depth maps "
        f"written to {stats['output_dir']}"
    )


if __name__ == "__main__":
    main()
