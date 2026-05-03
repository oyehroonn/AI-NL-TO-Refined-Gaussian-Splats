#!/usr/bin/env python3
"""
Layer 6 — Post-Splat Quality Analysis.

CLI entry point and pipeline-callable function.

Usage (standalone):
  PYTHONPATH=upload_to_splat python -m splat_quality_layer.run_layer6 --run-dir runs/<id>
  PYTHONPATH=upload_to_splat python -m splat_quality_layer.run_layer6 --run-dir runs/... --ply outputs/output_ply/splat.ply

Pipeline call:
  from splat_quality_layer.run_layer6 import run_layer6
  summary = run_layer6(run_dir, verbose=True)
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


# ── Pipeline-callable entry ───────────────────────────────────────────────────

def run_layer6(
    run_dir: Path,
    *,
    ply_path: Path | None = None,
    verbose: bool = True,
    save_heatmaps: bool = True,
    save_numpy_grids: bool = False,
) -> dict:
    """
    Run Layer 6 quality analysis on a completed Brush run.

    Parameters
    ----------
    run_dir          : pipeline run root (must contain outputs/output_ply/*.ply,
                       sparse/0/, optionally dpt/ and outputs/output_ply/eval_<iter>/)
    ply_path         : explicit .ply path (auto-detected if None)
    verbose          : print progress
    save_heatmaps    : write per-view error PNGs to layer6_heatmaps/
    save_numpy_grids : save coverage/depth .npy arrays to run_dir/

    Returns
    -------
    dict — pipeline metadata summary (written into stages["layer6_quality"])
    """
    # Ensure upload_to_splat/ is on sys.path so brush_packaging_layer.colmap_reader resolves
    this_dir = Path(__file__).resolve().parent          # upload_to_splat/splat_quality_layer/
    upload   = this_dir.parent                          # upload_to_splat/
    if str(upload) not in sys.path:
        sys.path.insert(0, str(upload))

    from .quality_reporter import run_quality_analysis

    return run_quality_analysis(
        run_dir,
        ply_path         = ply_path,
        verbose          = verbose,
        save_heatmaps    = save_heatmaps,
        save_numpy_grids = save_numpy_grids,
    )


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Layer 6: post-splat quality analysis.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--run-dir",
        type=Path,
        required=True,
        help="Pipeline run root directory (e.g. runs/20260415T120000Z_myvideo).",
    )
    parser.add_argument(
        "--ply",
        type=Path,
        default=None,
        dest="ply_path",
        help="Explicit path to the .ply file (default: auto-detect in outputs/output_ply/).",
    )
    parser.add_argument(
        "--no-heatmaps",
        action="store_true",
        help="Do not save per-view error heatmap PNGs.",
    )
    parser.add_argument(
        "--save-numpy-grids",
        action="store_true",
        help="Save coverage and depth mismatch arrays as .npy files.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress progress output (errors still shown).",
    )
    args = parser.parse_args()

    summary = run_layer6(
        args.run_dir,
        ply_path         = args.ply_path,
        verbose          = not args.quiet,
        save_heatmaps    = not args.no_heatmaps,
        save_numpy_grids = args.save_numpy_grids,
    )

    grade = summary.get("quality_grade", "?")
    n     = summary.get("n_issues", 0)
    print(f"\nDone.  Grade: {grade}  |  Issues: {n}")
    print(f"Report: {summary.get('layer6_quality_json', '?')}")


if __name__ == "__main__":
    # Allow direct execution: ensure upload_to_splat/ is on sys.path
    _upload = Path(__file__).resolve().parent.parent
    if str(_upload) not in sys.path:
        sys.path.insert(0, str(_upload))
    main()
