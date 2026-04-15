"""
Layer 6 — Quality Reporter (orchestrator).

Runs all four analysis engines, classifies issues, computes a grade, and:
  1. Writes metadata/layer6_quality.json
  2. Prints a coloured console report (mirrors Layer 3 style)
  3. Saves numpy grids to run_dir/ (optional, large arrays)

Returns a summary dict for pipeline metadata.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

from .ply_analyzer      import analyze_ply
from .coverage_analyzer import analyze_coverage
from .render_analyzer   import analyze_renders
from .depth_comparator  import analyze_depth
from .issue_classifier  import classify_issues, compute_quality_grade


# ── ANSI colours (mirroring Layer 3) ─────────────────────────────────────────

def _c(text: str, code: str) -> str:
    if not sys.stdout.isatty():
        return text
    return f"\033[{code}m{text}\033[0m"

_RED    = "31"
_YELLOW = "33"
_GREEN  = "32"
_CYAN   = "36"
_BOLD   = "1"
_DIM    = "2"


def _sev_colour(sev: str) -> str:
    return {"CRITICAL": _RED, "WARNING": _YELLOW, "INFO": _CYAN}.get(sev, _DIM)


def _grade_colour(grade: str) -> str:
    return {
        "EXCELLENT": _GREEN,
        "GOOD":      _GREEN,
        "FAIR":      _YELLOW,
        "POOR":      _RED,
        "FAILED":    _RED,
    }.get(grade, _DIM)


# ── JSON serialisation helper ─────────────────────────────────────────────────

def _strip_private(d: dict) -> dict:
    """Remove keys starting with '_' (numpy arrays not JSON-serialisable)."""
    return {k: v for k, v in d.items() if not k.startswith("_")}


def _json_safe(obj: Any) -> Any:
    if isinstance(obj, dict):
        return {k: _json_safe(v) for k, v in obj.items() if not k.startswith("_")}
    if isinstance(obj, list):
        return [_json_safe(v) for v in obj]
    if isinstance(obj, np.ndarray):
        return obj.tolist()
    if isinstance(obj, (np.integer,)):
        return int(obj)
    if isinstance(obj, (np.floating,)):
        return float(obj)
    return obj


# ── Console report ────────────────────────────────────────────────────────────

def _print_report(
    grade:    str,
    issues:   list[dict],
    ply:      dict,
    coverage: dict,
    render:   dict,
    depth:    dict,
) -> None:
    print()
    print(_c("━" * 70, _BOLD))
    print(_c("  Layer 6 — Post-Splat Quality Analysis", _BOLD))
    print(_c("━" * 70, _BOLD))

    # Grade banner
    grade_col = _grade_colour(grade)
    print(f"\n  Overall Quality Grade:  {_c(grade, grade_col + ';' + _BOLD)}\n")

    # PLY summary
    if ply.get("ok"):
        n  = ply["total_gaussians"]
        fs = ply.get("floater_stats", {})
        ss = ply.get("scale_stats", {})
        op = ply.get("opacity_stats", {})
        print(_c("  PLY Analysis", _CYAN + ";" + _BOLD))
        print(f"    Gaussians total     : {n:,}")
        if fs:
            print(f"    Floater fraction    : {fs['fraction']*100:.2f}%  "
                  f"({fs['count']:,} Gaussians)")
        if ss:
            p95 = ss['relative_to_scene']['p95_max_scale_frac']
            fov = ss['fraction_oversized']
            print(f"    Oversized fraction  : {fov*100:.2f}%  (P95 scale/scene={p95:.4f})")
        if op:
            print(f"    Opacity mean        : {op['mean']:.3f}   "
                  f"(below-0.1 fraction: {op['fraction_below_01']*100:.1f}%)")
        print()

    # Coverage summary
    if coverage.get("ok"):
        vs = coverage.get("visibility_stats", {})
        print(_c("  Coverage Analysis", _CYAN + ";" + _BOLD))
        if vs:
            print(f"    Mean visibility     : {vs['mean_visibility']:.1f} cameras/Gaussian")
            print(f"    Unseen fraction     : {vs['unseen_fraction']*100:.2f}%")
            print(f"    Weak (≤2 cam) frac  : {vs['weak_fraction']*100:.2f}%")
        print()

    # Render summary
    if render.get("ok"):
        gs = render.get("global_stats", {})
        print(_c("  Render Analysis", _CYAN + ";" + _BOLD))
        if gs:
            p  = gs["psnr"]
            s  = gs["ssim"]
            l1 = gs["l1_error"]
            print(f"    PSNR mean/min       : {p['mean']:.2f} dB / {p['min']:.2f} dB  "
                  f"(good ≥ 30 dB)")
            print(f"    SSIM mean           : {s['mean']:.4f}  (good ≥ 0.85)")
            print(f"    L1 error mean       : {l1['mean']:.5f}")
            print(f"    Views analyzed      : {render['n_views_analyzed']}")
            w5 = gs.get("worst_5_views", [])
            if w5:
                print(f"    Worst 5 views       : {', '.join(w5)}")
            if render.get("heatmap_dir"):
                print(f"    Heatmaps saved to   : {render['heatmap_dir']}")
        print()
    elif not render.get("available", False):
        print(_c("  Render Analysis: skipped (no eval renders found)", _DIM))
        print()

    # Depth summary
    if depth.get("ok"):
        print(_c("  Depth Analysis", _CYAN + ";" + _BOLD))
        print(f"    Mismatch fraction   : {depth['global_mismatch_fraction']*100:.2f}%")
        print(f"    Cameras analyzed    : {depth.get('n_cameras_analyzed', '?')}")
        print()
    elif not depth.get("available", False):
        print(_c("  Depth Analysis: skipped (no dpt/ folder)", _DIM))
        print()

    # Issues
    if issues:
        print(_c("  Issues detected", _BOLD))
        for iss in issues:
            sev   = iss["severity"]
            col   = _sev_colour(sev)
            badge = f"[{sev}]"
            print(f"    {_c(badge, col + ';' + _BOLD)}  {_c(iss['code'], _BOLD)}")
            print(f"        {iss['detail']}")
            print(f"        Fix: {_c(iss['fix'], _DIM)}")
            print()
    else:
        print(_c("  No issues detected!", _GREEN + ";" + _BOLD))
        print()

    print(_c("━" * 70, _BOLD))
    print()


# ── Main orchestrator ─────────────────────────────────────────────────────────

def run_quality_analysis(
    run_dir: Path,
    *,
    ply_path: Path | None = None,
    verbose: bool = True,
    save_heatmaps: bool = True,
    save_numpy_grids: bool = False,
) -> dict:
    """
    Full Layer 6 quality analysis.

    Parameters
    ----------
    run_dir          : pipeline run root (e.g. runs/20260415T120000Z_myvideo/)
    ply_path         : explicit path to .ply (default: auto-detect in outputs/splat/)
    verbose          : print progress lines
    save_heatmaps    : write per-view error PNGs to layer6_heatmaps/
    save_numpy_grids : save .npy coverage/density arrays to run_dir/

    Returns
    -------
    summary dict written into pipeline metadata.
    """
    t_start = time.perf_counter()
    run_dir = run_dir.resolve()
    meta_dir = run_dir / "metadata"
    meta_dir.mkdir(parents=True, exist_ok=True)

    # ── Auto-detect PLY path ──────────────────────────────────────────────────
    if ply_path is None:
        splat_dir = run_dir / "outputs" / "splat"
        candidates = sorted(splat_dir.glob("*.ply")) if splat_dir.is_dir() else []
        if candidates:
            ply_path = candidates[-1]   # take the most recently written

    sparse_dir = run_dir / "sparse" / "0"

    if verbose:
        print(f"\n[Layer 6] Starting quality analysis for {run_dir.name}")
        if ply_path:
            print(f"  PLY  : {ply_path}")
        print(f"  COLMAP: {sparse_dir}")

    # ── Engine 1: PLY ─────────────────────────────────────────────────────────
    if verbose:
        print("[Layer 6] 1/4 PLY analysis …")
    ply_result = analyze_ply(ply_path) if ply_path else {"ok": False, "error": "no .ply found"}

    # ── Engine 2: Coverage ────────────────────────────────────────────────────
    if verbose:
        print("[Layer 6] 2/4 Coverage analysis …")
    if ply_result.get("ok") and sparse_dir.is_dir():
        cov_result = analyze_coverage(sparse_dir, ply_result, verbose=verbose)
    else:
        cov_result = {
            "ok": False,
            "error": "PLY analysis failed or COLMAP sparse/ missing",
        }

    # ── Engine 3: Render ──────────────────────────────────────────────────────
    if verbose:
        print("[Layer 6] 3/4 Render analysis …")
    rnd_result = analyze_renders(run_dir, save_heatmaps=save_heatmaps, verbose=verbose)

    # ── Engine 4: Depth ───────────────────────────────────────────────────────
    if verbose:
        print("[Layer 6] 4/4 Depth comparison …")
    dpt_result = analyze_depth(run_dir, ply_result, verbose=verbose)

    # ── Issue classification ──────────────────────────────────────────────────
    issues = classify_issues(ply_result, cov_result, rnd_result, dpt_result)
    grade  = compute_quality_grade(issues, rnd_result)

    if verbose:
        print(f"[Layer 6] Grade: {grade}  Issues: {len(issues)}")

    # ── Save numpy grids (optional) ───────────────────────────────────────────
    if save_numpy_grids:
        if cov_result.get("_visibility_count") is not None:
            np.save(
                str(run_dir / "layer6_coverage_map.npy"),
                cov_result["_visibility_count"],
            )
        if dpt_result.get("_depth_mismatch_mask") is not None:
            np.save(
                str(run_dir / "layer6_depth_mismatch_mask.npy"),
                dpt_result["_depth_mismatch_mask"],
            )

    # ── Assemble full output ──────────────────────────────────────────────────
    elapsed = round(time.perf_counter() - t_start, 2)
    output: dict = {
        "schema_version":   1,
        "run_dir":          str(run_dir),
        "ply_path":         str(ply_path) if ply_path else None,
        "quality_grade":    grade,
        "n_issues":         len(issues),
        "issues":           issues,
        "ply":              _json_safe(ply_result),
        "coverage":         _json_safe(cov_result),
        "render":           _json_safe(rnd_result),
        "depth":            _json_safe(dpt_result),
        "analysis_seconds": elapsed,
    }

    # ── Write JSON ────────────────────────────────────────────────────────────
    out_path = meta_dir / "layer6_quality.json"
    tmp = out_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    tmp.replace(out_path)
    if verbose:
        print(f"[Layer 6] Results written to {out_path}")

    # ── Console report ────────────────────────────────────────────────────────
    _print_report(grade, issues, ply_result, cov_result, rnd_result, dpt_result)

    # ── Return pipeline-friendly summary ──────────────────────────────────────
    summary: dict = {
        "quality_grade": grade,
        "n_issues": len(issues),
        "issue_codes": [i["code"] for i in issues],
        "n_critical": sum(1 for i in issues if i["severity"] == "CRITICAL"),
        "n_warning":  sum(1 for i in issues if i["severity"] == "WARNING"),
        "analysis_seconds": elapsed,
        "layer6_quality_json": str(out_path),
    }

    if ply_result.get("ok"):
        summary["total_gaussians"] = ply_result.get("total_gaussians")
        summary["floater_fraction"] = (
            ply_result.get("floater_stats", {}).get("fraction")
        )
    if rnd_result.get("ok") and rnd_result.get("global_stats"):
        summary["mean_psnr_db"] = rnd_result["global_stats"]["psnr"]["mean"]
        summary["mean_ssim"]    = rnd_result["global_stats"]["ssim"]["mean"]

    return summary
