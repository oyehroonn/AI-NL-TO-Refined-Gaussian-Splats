"""
Brush quality presets, interactive menu, and command builder.

Presets
───────
draft    :  8,000 steps — quick sanity-check render (~5–15 min)
standard : 30,000 steps — normal quality, Brush default (~30–60 min)
quality  : 100,000 steps — LPIPS perceptual loss, slow densification (~2–4 hr)
custom   : user sets every parameter manually

Tuning notes (from brush-train/src/config.rs)
─────────────────────────────────────────────
growth_grad_threshold  : lower → more Gaussians grow faster (default 0.00004)
growth_select_fraction : fraction of growth candidates that actually grow (default 0.10)
growth_stop_iter       : densification stops here; should be ~40–50% of total_steps
refine_every           : densification frequency; Brush says "≈ number of images
                         to cover the scene" — we auto-set to n_images // 2
lpips_loss_weight      : VGG perceptual loss; 0.05 gives a big quality jump,
                         0.0 is default (off).  Adds ~40% compute overhead.
eval_split_every       : hold out every Nth image for eval metrics (PSNR/SSIM)
"""
from __future__ import annotations

import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

PresetName = Literal["draft", "standard", "quality", "custom"]

# ── Preset definitions ────────────────────────────────────────────────────────

@dataclass
class BrushRunConfig:
    preset: str                         # "draft" | "standard" | "quality" | "custom"
    total_steps: int
    growth_stop_iter: int               # densification cutoff step
    lpips_loss_weight: float            # 0.0 = off, 0.05 = quality
    growth_grad_threshold: float        # lower = more Gaussians
    growth_select_fraction: float       # fraction of candidates that grow
    # None = auto-derive from n_registered_images
    refine_every: int | None = None
    max_splats: int = 10_000_000
    eval_split_every: int = 8           # hold out every 8th image for eval metrics
    eval_save_to_disk: bool = True      # write rendered eval images alongside PLY
    export_every: int | None = None     # None = auto (~4 checkpoints across training)
    eval_every: int = 2000              # how often to run eval during training

    def effective_refine_every(self, n_registered_images: int) -> int:
        if self.refine_every is not None:
            return self.refine_every
        # Brush comment: "roughly the number of images to cover the scene"
        # For dense multi-view, n_images // 2 works well.
        return max(50, n_registered_images // 2)

    def effective_export_every(self) -> int:
        if self.export_every is not None:
            return self.export_every
        # Brush's training loop is `0..total_steps` (exclusive), so an
        # export_every == total_steps never fires. Use total_steps // 4 so we
        # land ~4 checkpoints across the run and always have a viewable .ply
        # even if training crashes or is interrupted before completion.
        return max(500, self.total_steps // 4)


_PRESETS: dict[str, BrushRunConfig] = {
    "draft": BrushRunConfig(
        preset="draft",
        total_steps=8_000,
        growth_stop_iter=5_000,
        lpips_loss_weight=0.0,
        growth_grad_threshold=0.00004,
        growth_select_fraction=0.10,
        eval_every=1000,
    ),
    "standard": BrushRunConfig(
        preset="standard",
        total_steps=30_000,
        growth_stop_iter=15_000,
        lpips_loss_weight=0.0,
        growth_grad_threshold=0.00004,
        growth_select_fraction=0.10,
        eval_every=2000,
    ),
    "quality": BrushRunConfig(
        preset="quality",
        total_steps=100_000,
        growth_stop_iter=40_000,
        lpips_loss_weight=0.05,
        growth_grad_threshold=0.00003,
        growth_select_fraction=0.15,
        eval_every=5000,
    ),
}

# ── Estimated wall-clock times per preset (rough, Apple M-series GPU) ─────────
_PRESET_TIME_EST: dict[str, str] = {
    "draft":    " ~5–15 min",
    "standard": " ~30–60 min",
    "quality":  " ~2–4 hr  ",
}


# ── Interactive menu ──────────────────────────────────────────────────────────

def _prompt(prompt: str, default: str) -> str:
    try:
        val = input(f"  {prompt} [{default}]: ").strip()
    except EOFError:
        return default
    return val if val else default


def quality_preset_menu(
    n_registered_images: int,
    colmap_stats: dict,
    *,
    interactive: bool = True,
    default_preset: str = "standard",
) -> BrushRunConfig:
    """
    Present an interactive quality preset menu and return a BrushRunConfig.

    When interactive=False, returns the default_preset without prompting.
    """
    if not interactive:
        cfg = _make_config(default_preset)
        print(f"[Brush] Non-interactive mode — using preset '{default_preset}'")
        return cfg

    n_pts   = colmap_stats.get("n_points", 0)
    n_imgs  = colmap_stats.get("n_images", n_registered_images)
    has_init = colmap_stats.get("has_dense_init", False)

    print()
    print("═" * 60)
    print("  Brush Training Quality")
    print("═" * 60)
    print(f"  COLMAP : {n_imgs} images | {n_pts:,} 3D points")
    if has_init:
        n_dense = colmap_stats.get("dense_init_points", 0)
        print(f"  Init   : {n_dense:,} dense points (from DPT depth maps) ✓")
    sky_masked = colmap_stats.get("sky_masks_generated", 0)
    if sky_masked:
        print(f"  Masks  : {sky_masked} sky masks generated ✓")
    print()
    print("  Select quality preset:")
    print(f"    1) Draft    —  8,000 steps |{_PRESET_TIME_EST['draft']}  | quick check")
    print(f"    2) Standard — 30,000 steps |{_PRESET_TIME_EST['standard']}| recommended")
    print(f"    3) Quality  — 100,000 steps |{_PRESET_TIME_EST['quality']}| LPIPS + slow densification")
    print("    4) Custom   — set parameters manually")
    print()

    preset_map = {"1": "draft", "2": "standard", "3": "quality", "4": "custom"}
    default_num = {"draft": "1", "standard": "2", "quality": "3", "custom": "4"}.get(
        default_preset, "2"
    )

    while True:
        raw = _prompt("Choice", default_num)
        if raw in preset_map:
            chosen = preset_map[raw]
            break
        # allow typing the name directly
        if raw.lower() in _PRESETS or raw.lower() == "custom":
            chosen = raw.lower()
            break
        print("  Enter 1–4.")

    if chosen == "custom":
        return _custom_menu(n_registered_images)

    cfg = _make_config(chosen)
    eff_refine = cfg.effective_refine_every(n_registered_images)
    print()
    print(f"  Preset  : {chosen}")
    print(f"  Steps   : {cfg.total_steps:,}")
    print(f"  Densify : every {eff_refine} steps, stop at {cfg.growth_stop_iter:,}")
    print(f"  LPIPS   : {cfg.lpips_loss_weight} ({'on' if cfg.lpips_loss_weight > 0 else 'off'})")
    print(f"  Eval    : every {cfg.eval_every} steps | split every {cfg.eval_split_every}th image")
    print()
    return cfg


def _make_config(preset_name: str) -> BrushRunConfig:
    import copy
    return copy.copy(_PRESETS[preset_name])


def _custom_menu(n_registered_images: int) -> BrushRunConfig:
    print()
    print("  Custom preset — press Enter to accept shown default.")
    print()

    total_steps        = int(_prompt("Total training steps", "30000"))
    growth_stop_iter   = int(_prompt("Densification stop step (< total_steps)", str(total_steps // 2)))
    refine_every_raw   = _prompt(f"Densify every N steps (blank = auto ~{max(50, n_registered_images // 2)})", "")
    refine_every       = int(refine_every_raw) if refine_every_raw else None
    lpips              = float(_prompt("LPIPS loss weight (0=off, 0.05=quality)", "0.0"))
    grad_thresh        = float(_prompt("Growth grad threshold (lower=more Gaussians)", "0.00004"))
    growth_frac        = float(_prompt("Growth select fraction (0.1–0.2)", "0.10"))
    eval_split         = int(_prompt("Eval split every Nth image (0=no eval)", "8"))
    eval_every         = int(_prompt("Eval every N steps", "2000"))

    return BrushRunConfig(
        preset="custom",
        total_steps=total_steps,
        growth_stop_iter=min(growth_stop_iter, total_steps - 1),
        lpips_loss_weight=lpips,
        growth_grad_threshold=grad_thresh,
        growth_select_fraction=growth_frac,
        refine_every=refine_every,
        eval_split_every=eval_split,
        eval_save_to_disk=(eval_split > 0),
        eval_every=eval_every,
    )


# ── Command builder ───────────────────────────────────────────────────────────

def build_brush_cmd(
    brush_bin: Path,
    dataset_dir: Path,
    cfg: BrushRunConfig,
    export_path: Path,
    n_registered_images: int,
    *,
    with_viewer: bool = False,
    headless: bool = False,
) -> list[str]:
    """
    Build the brush_app command list from a BrushRunConfig.

    brush_bin       : path to brush_app binary
    dataset_dir     : run root (must contain sparse/0/ + images/)
    cfg             : training config from preset or custom
    export_path     : where PLY exports go (and eval renders)
    with_viewer     : pass --with-viewer flag
    """
    eff_refine  = cfg.effective_refine_every(n_registered_images)
    eff_export  = cfg.effective_export_every()

    cmd: list[str] = [
        str(brush_bin),
        str(dataset_dir),
        # ── Training ──────────────────────────────────────────────────────
        "--total-steps",            str(cfg.total_steps),
        "--growth-stop-iter",       str(cfg.growth_stop_iter),
        "--refine-every",           str(eff_refine),
        "--growth-grad-threshold",  str(cfg.growth_grad_threshold),
        "--growth-select-fraction", str(cfg.growth_select_fraction),
        "--lpips-loss-weight",      str(cfg.lpips_loss_weight),
        # ── Export ────────────────────────────────────────────────────────
        "--export-path",            str(export_path),
        "--export-every",           str(eff_export),
    ]

    # Eval split
    if cfg.eval_split_every and cfg.eval_split_every > 0:
        cmd += ["--eval-split-every", str(cfg.eval_split_every)]
        cmd += ["--eval-every", str(cfg.eval_every)]
        if cfg.eval_save_to_disk:
            cmd += ["--eval-save-to-disk"]

    if with_viewer:
        cmd.append("--with-viewer")

    return cmd
