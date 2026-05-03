"""
Layer 6 — Render Analyzer.

Compares Brush eval renders (saved during training) against the original
input frames to compute pixel-level quality metrics and error heatmaps.

Brush eval convention (eval_save_to_disk=True):
  outputs/output_ply/eval_<step>/<image_name>.png   — rendered held-out frame

We walk for the LATEST eval_<step>/ checkpoint folder and match renders to
their source images by filename stem.

Metrics per view:
  PSNR  — Peak Signal-to-Noise Ratio (higher = better; >30 dB is good)
  SSIM  — Structural Similarity [0,1] (higher = better; >0.85 is good)
  L1    — Mean absolute pixel error [0,1] (lower = better)

Deps: numpy + cv2 (already in env from layers 2-3).
"""
from __future__ import annotations

import math
from pathlib import Path
from typing import NamedTuple

import cv2
import numpy as np


# ── SSIM (no scipy dep) ───────────────────────────────────────────────────────

def _ssim(a: np.ndarray, b: np.ndarray) -> float:
    """
    Compute SSIM between two uint8 BGR images of the same shape.
    Uses a 11×11 Gaussian window; returns scalar in [-1, 1].
    """
    if a.shape != b.shape:
        b = cv2.resize(b, (a.shape[1], a.shape[0]), interpolation=cv2.INTER_AREA)

    a_f = a.astype(np.float64) / 255.0
    b_f = b.astype(np.float64) / 255.0

    k_size = 11
    sigma  = 1.5
    kernel = cv2.getGaussianKernel(k_size, sigma)
    kernel = kernel @ kernel.T   # (11,11)

    C1, C2 = 0.01 ** 2, 0.03 ** 2

    ssim_vals: list[float] = []
    for c in range(a_f.shape[2]):
        mu_a = cv2.filter2D(a_f[:, :, c], -1, kernel)
        mu_b = cv2.filter2D(b_f[:, :, c], -1, kernel)
        mu_a2 = mu_a ** 2
        mu_b2 = mu_b ** 2
        mu_ab = mu_a * mu_b

        sig_a2 = cv2.filter2D(a_f[:, :, c] ** 2, -1, kernel) - mu_a2
        sig_b2 = cv2.filter2D(b_f[:, :, c] ** 2, -1, kernel) - mu_b2
        sig_ab = cv2.filter2D(a_f[:, :, c] * b_f[:, :, c], -1, kernel) - mu_ab

        num  = (2 * mu_ab + C1) * (2 * sig_ab + C2)
        den  = (mu_a2 + mu_b2 + C1) * (sig_a2 + sig_b2 + C2)
        ssim_map = np.where(den > 0, num / den, 0.0)
        ssim_vals.append(float(ssim_map.mean()))

    return float(np.mean(ssim_vals))


# ── PSNR ──────────────────────────────────────────────────────────────────────

def _psnr(a: np.ndarray, b: np.ndarray) -> float:
    """PSNR in dB; returns inf if identical."""
    if a.shape != b.shape:
        b = cv2.resize(b, (a.shape[1], a.shape[0]), interpolation=cv2.INTER_AREA)
    mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
    if mse == 0:
        return float("inf")
    return 10.0 * math.log10(255.0 ** 2 / mse)


# ── Eval render discovery ─────────────────────────────────────────────────────

class _EvalMatch(NamedTuple):
    stem: str
    render_path: Path
    source_path: Path
    step: int


def _find_eval_renders(run_dir: Path) -> list[_EvalMatch]:
    """
    Find the latest Brush eval render folder and match renders → sources.

    Brush saves to:  run_dir/outputs/splat/eval/<step>/<image_name>.png
    Source images:   run_dir/source/<image_name>  (or images/)
    """
    eval_root = run_dir / "outputs" / "splat" / "eval"
    if not eval_root.is_dir():
        return []

    # Pick the step folder with the highest number (= latest checkpoint)
    step_dirs = sorted(
        [d for d in eval_root.iterdir() if d.is_dir() and d.name.isdigit()],
        key=lambda d: int(d.name),
    )
    if not step_dirs:
        return []
    latest_step = step_dirs[-1]
    step_num = int(latest_step.name)

    # Find source image directory (COLMAP renames images/ → source/)
    source_dir: Path | None = None
    for candidate in (run_dir / "source", run_dir / "images"):
        if candidate.is_dir():
            source_dir = candidate
            break
    if source_dir is None:
        return []

    # Index source images by stem (case-insensitive)
    source_index: dict[str, Path] = {}
    for p in source_dir.iterdir():
        if p.is_file() and p.suffix.lower() in (".jpg", ".jpeg", ".png", ".bmp"):
            source_index[p.stem.lower()] = p

    matches: list[_EvalMatch] = []
    for render in sorted(latest_step.iterdir()):
        if not render.is_file():
            continue
        stem = render.stem.lower()
        src = source_index.get(stem)
        if src is None:
            continue
        matches.append(_EvalMatch(
            stem=render.stem,
            render_path=render,
            source_path=src,
            step=step_num,
        ))

    return matches


# ── Per-view analysis ─────────────────────────────────────────────────────────

def _analyze_pair(
    render_path: Path,
    source_path: Path,
    heatmap_dir: Path | None,
    stem: str,
) -> dict:
    """Compare one render vs one source image. Returns per-view metrics dict."""
    render = cv2.imread(str(render_path))
    source = cv2.imread(str(source_path))

    if render is None or source is None:
        return {"stem": stem, "ok": False, "error": "failed to load image"}

    # Resize source to render resolution if they differ
    if source.shape[:2] != render.shape[:2]:
        source = cv2.resize(
            source,
            (render.shape[1], render.shape[0]),
            interpolation=cv2.INTER_AREA,
        )

    psnr  = _psnr(render, source)
    ssim  = _ssim(render, source)
    l1    = float(np.mean(np.abs(render.astype(np.float32) - source.astype(np.float32))) / 255.0)

    # Error heatmap: absolute diff, colourised
    if heatmap_dir is not None:
        heatmap_dir.mkdir(parents=True, exist_ok=True)
        diff = np.abs(render.astype(np.float32) - source.astype(np.float32)).mean(axis=2)
        diff_u8 = np.clip(diff, 0, 255).astype(np.uint8)
        heat    = cv2.applyColorMap(diff_u8, cv2.COLORMAP_JET)
        cv2.imwrite(str(heatmap_dir / f"{stem}_error.png"), heat)

    return {
        "stem":          stem,
        "ok":            True,
        "psnr_db":       round(psnr, 3) if math.isfinite(psnr) else 100.0,
        "ssim":          round(ssim, 4),
        "l1_error":      round(l1,   5),
        "render_path":   str(render_path),
        "source_path":   str(source_path),
    }


# ── Main entry point ──────────────────────────────────────────────────────────

def analyze_renders(
    run_dir: Path,
    *,
    save_heatmaps: bool = True,
    verbose: bool = False,
) -> dict:
    """
    Find Brush eval renders, compare to source images, compute quality metrics.

    Returns a dict:
      ok, eval_step, n_views_analyzed,
      per_view_metrics (list of dicts sorted worst→best by psnr),
      global_stats (mean/median PSNR, SSIM, L1; worst_5 views),
      heatmap_dir (str path or None).
    """
    result: dict = {"ok": False, "error": None, "available": False}

    matches = _find_eval_renders(run_dir)
    if not matches:
        result["error"] = (
            "No eval renders found. Expected outputs/splat/eval/<step>/<name>.png. "
            "Ensure eval_save_to_disk=True in brush_config.py (it is by default)."
        )
        return result

    result["available"]  = True
    result["eval_step"]  = matches[0].step

    heatmap_dir: Path | None = None
    if save_heatmaps:
        heatmap_dir = run_dir / "layer6_heatmaps"

    if verbose:
        print(f"  [render] analyzing {len(matches)} eval views (step {matches[0].step})")

    per_view: list[dict] = []
    for m in matches:
        v = _analyze_pair(m.render_path, m.source_path, heatmap_dir, m.stem)
        per_view.append(v)

    good_views = [v for v in per_view if v.get("ok")]
    if not good_views:
        result["error"] = "All image pairs failed to load"
        return result

    psnr_vals  = [v["psnr_db"]  for v in good_views]
    ssim_vals  = [v["ssim"]     for v in good_views]
    l1_vals    = [v["l1_error"] for v in good_views]

    # Sort worst → best (ascending PSNR = worst first)
    per_view_sorted = sorted(good_views, key=lambda v: v["psnr_db"])

    result["n_views_analyzed"] = len(good_views)
    result["per_view_metrics"] = per_view_sorted

    result["global_stats"] = {
        "psnr": {
            "mean":   round(float(np.mean(psnr_vals)),   3),
            "median": round(float(np.median(psnr_vals)), 3),
            "min":    round(float(np.min(psnr_vals)),    3),
            "max":    round(float(np.max(psnr_vals)),    3),
            "p10":    round(float(np.percentile(psnr_vals, 10)), 3),
        },
        "ssim": {
            "mean":   round(float(np.mean(ssim_vals)),   4),
            "median": round(float(np.median(ssim_vals)), 4),
            "min":    round(float(np.min(ssim_vals)),    4),
        },
        "l1_error": {
            "mean":   round(float(np.mean(l1_vals)),   5),
            "median": round(float(np.median(l1_vals)), 5),
            "max":    round(float(np.max(l1_vals)),    5),
        },
        "worst_5_views": [v["stem"] for v in per_view_sorted[:5]],
    }

    result["heatmap_dir"] = str(heatmap_dir) if heatmap_dir else None
    result["ok"] = True
    return result
