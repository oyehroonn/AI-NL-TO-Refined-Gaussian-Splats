"""
Layer 7 — Context Builder.

Reads metadata/run_metadata.json, metadata/layer3_audit.json, and
metadata/layer6_quality.json from a run directory and assembles a
single clean context dict for the prompt builder.
"""
from __future__ import annotations

import json
from pathlib import Path


def _load_json(path: Path) -> dict | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def build_context(run_dir: Path) -> dict:
    """
    Load all available analysis files and return a unified context dict.

    Keys: run, config, stages, layer2, layer3, layer6.
    All values use .get() with safe defaults — no KeyError possible.
    """
    run_dir = run_dir.resolve()
    meta_dir = run_dir / "metadata"

    run_meta = _load_json(meta_dir / "run_metadata.json") or {}
    l3_raw   = _load_json(meta_dir / "layer3_audit.json")
    l6_raw   = _load_json(meta_dir / "layer6_quality.json")

    # ── Run overview ──────────────────────────────────────────────────────────
    paths = run_meta.get("paths", {})
    src   = paths.get("source_video_original") or paths.get("input_video", "")
    run = {
        "run_id":     run_meta.get("run_id", run_dir.name),
        "video_name": Path(src).name if src else run_dir.name,
        "created_at": run_meta.get("created_at", ""),
        "status":     run_meta.get("status", "unknown"),
    }

    # ── Pipeline config ───────────────────────────────────────────────────────
    cfg = run_meta.get("config", {})

    # ── Stage status map ──────────────────────────────────────────────────────
    stages = run_meta.get("stages", {})

    # ── Layer 2 summary (from stage metrics in run_metadata.json) ─────────────
    l2_stage = stages.get("layer2_quality", {})
    l2_met   = l2_stage.get("metrics", {}) or {}
    rr       = l2_met.get("reject_reasons", {}) or {}
    layer2 = {
        "available":  l2_stage.get("status") == "completed",
        "n_kept":     l2_met.get("n_kept", 0),
        "n_rejected": l2_met.get("n_rejected", 0),
        "n_total":    l2_met.get("n_total", 0),
        "n_blur":     sum(1 for v in rr.values() if "blur"      in str(v).lower()),
        "n_dup":      sum(1 for v in rr.values() if "duplicate" in str(v).lower()),
        "n_exposure": sum(1 for v in rr.values() if "exposure"  in str(v).lower()),
        "n_static":   sum(1 for v in rr.values() if "static"    in str(v).lower()),
    }

    # ── Layer 3 (pre-COLMAP audit) ────────────────────────────────────────────
    if l3_raw:
        summ = l3_raw.get("summary", {})
        inv  = l3_raw.get("frame_inventory", {})
        layer3: dict = {
            "available":        True,
            "readiness":        summ.get("colmap_readiness", "UNKNOWN"),
            "quality_score":    summ.get("quality_score", 0.0),
            "n_critical":       summ.get("n_critical", 0),
            "n_warnings":       summ.get("n_warnings", 0),
            "n_info":           summ.get("n_info", 0),
            "recommendation":   summ.get("recommendation", ""),
            "n_frames":         inv.get("n_frames_kept", 0),
            "n_rejected_blur":  inv.get("n_rejected_blur", 0),
            "n_rejected_dup":   inv.get("n_rejected_duplicate", 0),
            "n_rejected_exp":   inv.get("n_rejected_exposure", 0),
            "n_rejected_stat":  inv.get("n_rejected_static", 0),
            "motion":           l3_raw.get("motion", {}),
            "texture":          l3_raw.get("texture", {}),
            "lighting":         l3_raw.get("lighting", {}),
            "coverage":         l3_raw.get("coverage", {}),
            "issues":           l3_raw.get("issues", []),
        }
    else:
        layer3 = {"available": False}

    # ── Layer 6 (post-splat quality) ──────────────────────────────────────────
    if l6_raw:
        layer6: dict = {
            "available":     True,
            "quality_grade": l6_raw.get("quality_grade", "UNKNOWN"),
            "n_issues":      l6_raw.get("n_issues", 0),
            "issues":        l6_raw.get("issues", []),
            "ply":           l6_raw.get("ply", {}),
            "coverage":      l6_raw.get("coverage", {}),
            "render":        l6_raw.get("render", {}),
            "depth":         l6_raw.get("depth", {}),
        }
    else:
        layer6 = {"available": False}

    return {
        "run":    run,
        "config": cfg,
        "stages": stages,
        "layer2": layer2,
        "layer3": layer3,
        "layer6": layer6,
    }
