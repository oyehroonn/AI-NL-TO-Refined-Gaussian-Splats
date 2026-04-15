"""
Layer 5 — Brush packaging + training wrapper.

Pipeline flow (all steps before Brush runs):
  1. validate_colmap   → fail fast if sparse/0/ is broken
  2. dense_init        → DPT depth maps + COLMAP cameras → init.ply
  3. sky_masks         → masks/ folder to suppress sky floaters
  4. quality preset    → interactive menu (draft / standard / quality / custom)
  5. run Brush         → passes all tuned flags
  6. collect stats     → write metadata/layer5_brush.json

CLI usage:
  python3 -m scripts.layer5.run_layer5 \\
      --run-dir runs/<id> \\
      --brush-bin brush/target/release/brush_app \\
      --preset standard
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from layer5.colmap_validator import validate_colmap   # noqa: E402
from layer5.dense_init       import generate_dense_init  # noqa: E402
from layer5.sky_masker       import generate_sky_masks   # noqa: E402
from layer5.brush_config     import (                     # noqa: E402
    BrushRunConfig,
    build_brush_cmd,
    quality_preset_menu,
)


def run_layer5(
    run_dir: Path,
    brush_bin: Path | None,
    *,
    sparse_dir: Path | None       = None,
    dpt_dir: Path | None          = None,
    images_dir: Path | None       = None,
    masks_dir: Path | None        = None,
    export_dir: Path | None       = None,
    # Feature toggles
    run_dense_init: bool          = True,
    run_sky_masks: bool           = True,
    run_brush: bool               = True,
    # Preset / menu
    preset: str                   = "auto",   # "auto" shows menu; else preset name
    interactive: bool             = True,
    default_preset: str           = "standard",
    # Brush misc
    with_viewer: bool             = False,
    n_samples_per_frame: int      = 2000,
    verbose: bool                 = True,
) -> dict:
    """
    Run Layer 5 end-to-end.

    run_dir    : pipeline run root (contains sparse/0/, dpt/, images/, etc.)
    brush_bin  : path to brush_app binary (None → skip Brush stage)
    preset     : "auto" (interactive menu) | "draft" | "standard" | "quality" | "custom"
    interactive: whether to show the quality menu (False = use default_preset silently)
    """
    run_dir = run_dir.resolve()

    sparse_dir  = (sparse_dir  or run_dir / "sparse"  / "0").resolve()
    dpt_dir     = (dpt_dir     or run_dir / "dpt"           ).resolve()
    images_dir  = _resolve_images_dir(run_dir, images_dir)
    masks_dir   = (masks_dir   or run_dir / "masks"         ).resolve()
    export_dir  = (export_dir  or run_dir / "outputs" / "splat").resolve()
    export_dir.mkdir(parents=True, exist_ok=True)

    meta_dir = run_dir / "metadata"
    meta_dir.mkdir(parents=True, exist_ok=True)

    result: dict = {
        "colmap_validation": {},
        "dense_init": {},
        "sky_masks": {},
        "brush": {},
    }
    t_total = time.perf_counter()

    # ── 1. COLMAP validation ──────────────────────────────────────────────────
    if verbose:
        print("\n[Layer 5] ── COLMAP validation ──────────────────────────────")
    colmap_stats = validate_colmap(sparse_dir, verbose=verbose)
    result["colmap_validation"] = colmap_stats

    if not colmap_stats["ok"]:
        print("[Layer 5] COLMAP validation FAILED — aborting Layer 5.")
        result["error"] = "COLMAP validation failed"
        _write_meta(meta_dir, result)
        return result

    # ── 2. Dense init.ply ─────────────────────────────────────────────────────
    if run_dense_init and dpt_dir.is_dir():
        if verbose:
            print("\n[Layer 5] ── Dense init.ply from DPT depth maps ───────────")
        init_stats = generate_dense_init(
            run_dir, sparse_dir, dpt_dir,
            n_samples_per_frame=n_samples_per_frame,
            verbose=verbose,
        )
        result["dense_init"] = init_stats
        if "error" in init_stats:
            print(f"[Layer 5] Dense init warning: {init_stats['error']} (continuing)")
        else:
            colmap_stats["has_dense_init"]     = True
            colmap_stats["dense_init_points"]  = init_stats.get("n_points", 0)
    else:
        reason = "disabled" if not run_dense_init else "dpt_dir missing (run Layer 4)"
        result["dense_init"] = {"skipped": True, "reason": reason}
        if verbose:
            print(f"[Layer 5] Dense init skipped — {reason}")

    # ── 3. Sky masks ──────────────────────────────────────────────────────────
    if run_sky_masks and images_dir.is_dir():
        if verbose:
            print("\n[Layer 5] ── Sky mask generation ───────────────────────────")
        sky_stats = generate_sky_masks(images_dir, masks_dir, verbose=verbose)
        result["sky_masks"] = sky_stats
        colmap_stats["sky_masks_generated"] = sky_stats.get("n_sky_detected", 0)
    else:
        reason = "disabled" if not run_sky_masks else f"images_dir missing ({images_dir})"
        result["sky_masks"] = {"skipped": True, "reason": reason}
        if verbose:
            print(f"[Layer 5] Sky masks skipped — {reason}")

    # ── 4. Quality preset selection ───────────────────────────────────────────
    n_reg_images = colmap_stats.get("n_images", 100)

    show_menu = (preset == "auto") and interactive
    cfg: BrushRunConfig = quality_preset_menu(
        n_reg_images,
        colmap_stats,
        interactive=show_menu,
        default_preset=default_preset if preset == "auto" else preset,
    )
    result["brush_config"] = {
        "preset":                cfg.preset,
        "total_steps":           cfg.total_steps,
        "growth_stop_iter":      cfg.growth_stop_iter,
        "refine_every":          cfg.effective_refine_every(n_reg_images),
        "lpips_loss_weight":     cfg.lpips_loss_weight,
        "growth_grad_threshold": cfg.growth_grad_threshold,
        "growth_select_fraction":cfg.growth_select_fraction,
        "eval_split_every":      cfg.eval_split_every,
        "eval_save_to_disk":     cfg.eval_save_to_disk,
    }

    # ── 5. Run Brush ──────────────────────────────────────────────────────────
    if not run_brush or brush_bin is None or not Path(brush_bin).is_file():
        reason = "disabled" if not run_brush else f"brush_app not found at {brush_bin}"
        result["brush"] = {"skipped": True, "reason": reason}
        if verbose:
            print(f"\n[Layer 5] Brush skipped — {reason}")
        _write_meta(meta_dir, result)
        return result

    cmd = build_brush_cmd(
        brush_bin    = Path(brush_bin),
        dataset_dir  = run_dir,
        cfg          = cfg,
        export_path  = export_dir,
        n_registered_images = n_reg_images,
        with_viewer  = with_viewer,
    )

    if verbose:
        print(f"\n[Layer 5] ── Running Brush ─────────────────────────────────")
        print(f"  Command: {' '.join(str(c) for c in cmd)}")

    t_brush = time.perf_counter()
    proc = subprocess.run(cmd, cwd=str(run_dir), check=False)
    brush_elapsed = time.perf_counter() - t_brush

    brush_ok = proc.returncode == 0

    # ── 6. Collect post-train stats ───────────────────────────────────────────
    exported_plys = sorted(export_dir.glob("*.ply"))
    final_ply = str(exported_plys[-1]) if exported_plys else None

    result["brush"] = {
        "ok":             brush_ok,
        "returncode":     proc.returncode,
        "elapsed_seconds": round(brush_elapsed, 1),
        "export_dir":     str(export_dir),
        "final_ply":      final_ply,
        "n_exported":     len(exported_plys),
    }

    total_elapsed = time.perf_counter() - t_total
    result["total_elapsed_seconds"] = round(total_elapsed, 1)

    if verbose:
        status = "✓ complete" if brush_ok else f"✗ failed (code {proc.returncode})"
        print(f"\n[Layer 5] Brush {status} in {brush_elapsed:.0f}s")
        if final_ply:
            print(f"[Layer 5] Splat → {final_ply}")

    _write_meta(meta_dir, result)
    return result


def _resolve_images_dir(run_dir: Path, override: Path | None) -> Path:
    if override is not None:
        return override.resolve()
    # After COLMAP: undistorted images/ (preferred) or source/
    for candidate in ("images", "source"):
        p = run_dir / candidate
        if p.is_dir():
            return p.resolve()
    return (run_dir / "images").resolve()


def _write_meta(meta_dir: Path, data: dict) -> None:
    path = meta_dir / "layer5_brush.json"
    path.write_text(json.dumps(data, indent=2, default=str) + "\n", encoding="utf-8")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Layer 5: Brush packaging + training wrapper.")
    parser.add_argument("--run-dir",    type=Path, required=True, help="Pipeline run directory.")
    parser.add_argument("--brush-bin",  type=Path, default=None,  help="Path to brush_app binary.")
    parser.add_argument(
        "--preset",
        default="auto",
        choices=["auto", "draft", "standard", "quality", "custom"],
        help="Quality preset (default: auto = show interactive menu).",
    )
    parser.add_argument(
        "--default-preset",
        default="standard",
        choices=["draft", "standard", "quality"],
        help="Preset used when non-interactive mode or auto with no TTY.",
    )
    parser.add_argument("--no-dense-init",  action="store_true", help="Skip dense init.ply generation.")
    parser.add_argument("--no-sky-masks",   action="store_true", help="Skip sky mask generation.")
    parser.add_argument("--no-brush",       action="store_true", help="Prepare assets only, do not train.")
    parser.add_argument("--with-viewer",    action="store_true", help="Open Brush viewer window.")
    parser.add_argument("--samples",        type=int, default=2000, help="DPT back-projection samples per frame.")
    parser.add_argument("--non-interactive", action="store_true", help="Skip the quality menu; use --default-preset.")
    args = parser.parse_args()

    stats = run_layer5(
        run_dir           = args.run_dir,
        brush_bin         = args.brush_bin,
        preset            = args.preset,
        default_preset    = args.default_preset,
        run_dense_init    = not args.no_dense_init,
        run_sky_masks     = not args.no_sky_masks,
        run_brush         = not args.no_brush,
        with_viewer       = args.with_viewer,
        interactive       = not args.non_interactive,
        n_samples_per_frame = args.samples,
        verbose           = True,
    )

    if stats.get("error"):
        print(f"\n[Layer 5] ERROR: {stats['error']}", file=sys.stderr)
        sys.exit(1)
    if stats.get("brush", {}).get("ok") is False:
        sys.exit(1)


if __name__ == "__main__":
    main()
