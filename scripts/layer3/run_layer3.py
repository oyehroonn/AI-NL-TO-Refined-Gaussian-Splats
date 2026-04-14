#!/usr/bin/env python3
"""
Layer 3 CLI — pre-COLMAP dataset audit.

Run standalone:
  python3 -m scripts.layer3.run_layer3 --images-dir runs/<id>/images

Or called by pipeline/run_pipeline.py as a stage between layer2 and colmap.

Outputs:
  metadata/layer3_audit.json   — full structured audit (NLP training data)
  Console summary with issues, trajectory ASCII, recommendations
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent.parent  # scripts/
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from layer3.audit_reporter import run_audit  # noqa: E402


def run_layer3(
    images_dir: Path,
    *,
    layer2_stats: dict | None = None,
    verbose: bool = True,
    halt_on_critical: bool = False,
) -> dict:
    """
    Pipeline integration entry point.

    images_dir      : path to (layer2-filtered) frames
    layer2_stats    : dict from run_layer2(), used for inventory counts
    verbose         : print console summary
    halt_on_critical: raise RuntimeError if critical issues detected

    Returns the full audit dict.
    """
    return run_audit(
        images_dir,
        layer2_stats=layer2_stats,
        verbose=verbose,
        halt_on_critical=halt_on_critical,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Layer 3: pre-COLMAP dataset audit.")
    parser.add_argument(
        "--images-dir",
        type=Path,
        required=True,
        help="Directory of (filtered) frames to audit.",
    )
    parser.add_argument(
        "--layer2-stats",
        type=Path,
        default=None,
        help="Path to layer2_scores.json (for inventory counts). "
             "Auto-detected from <images_dir>/../metadata/layer2_scores.json if omitted.",
    )
    parser.add_argument(
        "--halt-on-critical",
        action="store_true",
        help="Exit with code 1 if any critical issues are found.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress console report (JSON still written).",
    )
    args = parser.parse_args()

    # Load layer2 stats if available
    l2_path = args.layer2_stats
    if l2_path is None:
        candidate = args.images_dir.resolve().parent / "metadata" / "layer2_scores.json"
        if candidate.exists():
            l2_path = candidate

    l2_stats: dict | None = None
    if l2_path and l2_path.exists():
        try:
            l2_stats = json.loads(l2_path.read_text())
        except Exception:
            pass

    try:
        audit = run_layer3(
            args.images_dir,
            layer2_stats=l2_stats,
            verbose=not args.quiet,
            halt_on_critical=args.halt_on_critical,
        )
    except RuntimeError as e:
        print(f"\n[Layer 3] Pipeline halted: {e}", file=sys.stderr)
        sys.exit(1)

    readiness = audit["summary"]["colmap_readiness"]
    print(f"Layer 3 audit complete. COLMAP readiness: {readiness}")


if __name__ == "__main__":
    main()
