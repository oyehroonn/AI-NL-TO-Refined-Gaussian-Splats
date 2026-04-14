#!/usr/bin/env python3
"""
Audit reporter — Layer 3 orchestrator.

Runs all analyzers on images_dir, assembles the full audit dict,
writes metadata/layer3_audit.json, and prints a rich console summary.

The audit dict schema (version 1):
  audit_schema_version    int
  timestamp               ISO8601
  run_id                  str (from parent directory name, if detectable)
  frame_inventory         {total, after_layer2, rejected_blur, rejected_dup, ...}
  motion                  motion_analyzer output
  texture                 texture_analyzer output
  lighting                lighting_analyzer output
  coverage                coverage_estimator output
  issues                  list of issue dicts (from issue_classifier)
  summary                 {quality_score, colmap_readiness, n_critical, n_warnings, recommendation}
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from .motion_analyzer import analyze_motion_sequence
from .texture_analyzer import analyze_texture
from .lighting_analyzer import analyze_lighting
from .coverage_estimator import estimate_coverage
from .issue_classifier import classify_issues

IMAGE_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png", ".bmp", ".tiff", ".tif"})

_SEVERITY_COLOR = {
    "critical": "\033[91m",   # red
    "warning":  "\033[93m",   # yellow
    "info":     "\033[94m",   # blue
}
_RESET = "\033[0m"
_BOLD  = "\033[1m"
_GREEN = "\033[92m"
_CYAN  = "\033[96m"


def _collect_images(images_dir: Path) -> list[Path]:
    return sorted(
        [p for p in images_dir.iterdir() if p.suffix.lower() in IMAGE_EXTENSIONS],
        key=lambda p: p.name,
    )


def _collect_rejected(run_dir: Path) -> tuple[int, int]:
    """Return (n_rejected_blur, n_rejected_dup) from layer2 metadata if present."""
    meta = run_dir / "metadata" / "layer2_scores.json"
    if not meta.exists():
        return 0, 0
    try:
        data = json.loads(meta.read_text())
        reasons = data.get("reject_reasons", {})
        blur = sum(1 for v in reasons.values() if "blur" in v)
        dup = sum(1 for v in reasons.values() if "duplicate" in v)
        return blur, dup
    except Exception:
        return 0, 0


def _quality_score(issues: list[dict]) -> float:
    """
    Composite quality score [0,1] based on issues.
    Starts at 1.0, penalised per issue.
    """
    penalty = {"critical": 0.25, "warning": 0.08, "info": 0.02}
    score = 1.0
    for issue in issues:
        sev = issue.get("severity", "info")
        conf = issue.get("confidence", 0.5)
        score -= penalty.get(sev, 0.02) * conf
    return round(max(0.0, score), 3)


def _colmap_readiness(score: float, issues: list[dict]) -> str:
    """
    FAIL  — critical issues with high/critical COLMAP impact (COLMAP will likely fail)
    POOR  — critical issues with only medium/low COLMAP impact (splat hurt, COLMAP may work)
    FAIR  — only warnings
    GOOD  — no issues or info-only
    """
    colmap_critical = [
        i for i in issues
        if i["severity"] == "critical" and i.get("colmap_impact") in ("critical", "high")
    ]
    splat_critical = [
        i for i in issues
        if i["severity"] == "critical" and i.get("colmap_impact") not in ("critical", "high")
    ]
    n_warnings = sum(1 for i in issues if i["severity"] == "warning")

    if colmap_critical or score < 0.35:
        return "FAIL"
    if splat_critical or score < 0.55:
        return "POOR"
    if n_warnings > 0 or score < 0.75:
        return "FAIR"
    return "GOOD"


def _recommendation(readiness: str, issues: list[dict]) -> str:
    if readiness == "FAIL":
        top = next(
            (i["title"] for i in issues
             if i["severity"] == "critical" and i.get("colmap_impact") in ("critical", "high")),
            next((i["title"] for i in issues if i["severity"] == "critical"), ""),
        )
        return (
            f"Re-capture recommended. Critical issue will likely cause COLMAP to fail: {top}. "
            "Fix this before running reconstruction."
        )
    if readiness == "POOR":
        top = next((i["title"] for i in issues if i["severity"] == "critical"), "")
        return (
            f"COLMAP will likely succeed but splat quality will be degraded. Critical: {top}. "
            "Consider re-capturing, or proceed knowing quality will be limited."
        )
    if readiness == "FAIR":
        return (
            "Dataset is usable. Address the listed warnings for cleaner splats. "
            "Proceeding with COLMAP."
        )
    return "Dataset looks good. Proceeding with COLMAP."


def _print_console_report(audit: dict, verbose: bool = True) -> None:
    summary = audit["summary"]
    issues  = audit["issues"]
    inv     = audit["frame_inventory"]
    cov     = audit["coverage"]
    motion  = audit["motion"]
    light   = audit["lighting"]

    readiness = summary["colmap_readiness"]
    score     = summary["quality_score"]

    readiness_color = {
        "GOOD": _GREEN, "FAIR": "\033[93m", "POOR": "\033[91m", "FAIL": "\033[91m"
    }.get(readiness, "")

    print(f"\n{_BOLD}{'─'*60}{_RESET}")
    print(f"{_BOLD}  Layer 3 — Dataset Audit{_RESET}")
    print(f"{'─'*60}")

    print(f"  Frames kept   : {inv['n_frames_kept']}")
    print(f"  Rejected blur : {inv['n_rejected_blur']}")
    print(f"  Rejected dup  : {inv['n_rejected_duplicate']}")
    print(f"  Quality score : {score:.2f}/1.00")
    print(f"  COLMAP ready  : {readiness_color}{_BOLD}{readiness}{_RESET}")

    print(f"\n  Motion  — rot:{motion['median_rotation_fraction']:.2f}  "
          f"trans:{motion['median_translation_px']:.1f}px  "
          f"dirs:{motion['n_directions_covered']}/8")
    print(f"  Lighting— stability:{light['lighting_stability_score']:.2f}  "
          f"L_mean:{light.get('brightness',{}).get('mean_L',0):.1f}  "
          f"cv:{light.get('brightness',{}).get('cv',0):.3f}")
    print(f"  Coverage— {cov['trajectory_type']}  "
          f"orbit:{cov['orbit_score']:.2f}  "
          f"loop:{cov['loop_closed']}")

    if cov.get("capture_path_ascii"):
        print(f"\n  Camera path (top-down):")
        for line in cov["capture_path_ascii"]:
            print(f"    {line}")

    if issues:
        print(f"\n  {'─'*56}")
        print(f"  Issues ({len(issues)} total):")
        for iss in issues:
            sev = iss["severity"]
            col = _SEVERITY_COLOR.get(sev, "")
            conf_str = f"{iss['confidence']*100:.0f}%"
            print(f"\n  {col}{_BOLD}[{sev.upper()} {conf_str}]{_RESET} {iss['title']}")
            if verbose:
                # Wrap detail at 56 chars
                words = iss["detail"].split()
                line, lines = "", []
                for w in words:
                    if len(line) + len(w) + 1 > 54:
                        lines.append(line)
                        line = w
                    else:
                        line = (line + " " + w).strip()
                if line:
                    lines.append(line)
                for l in lines:
                    print(f"    {l}")
                print(f"    {_CYAN}Fix: {iss['suggested_fix'][:80]}...{_RESET}"
                      if len(iss["suggested_fix"]) > 80
                      else f"    {_CYAN}Fix: {iss['suggested_fix']}{_RESET}")
                print(f"    COLMAP impact: {iss['colmap_impact']}  Splat impact: {iss['splat_impact']}")
    else:
        print(f"\n  {_GREEN}No issues detected.{_RESET}")

    print(f"\n  {'─'*56}")
    print(f"  {_BOLD}Recommendation:{_RESET} {summary['recommendation']}")
    print(f"{'─'*60}\n")


def run_audit(
    images_dir: Path,
    *,
    layer2_stats: dict | None = None,
    verbose: bool = True,
    halt_on_critical: bool = False,
) -> dict:
    """
    Full Layer 3 audit.

    images_dir       : path to the (already-filtered) frames folder
    layer2_stats     : dict from run_layer2 (used for frame counts)
    verbose          : print rich console report
    halt_on_critical : raise RuntimeError if critical issues found

    Returns audit dict (also written to metadata/layer3_audit.json).
    """
    images_dir = images_dir.resolve()
    run_dir    = images_dir.parent
    meta_dir   = run_dir / "metadata"
    meta_dir.mkdir(parents=True, exist_ok=True)

    frames = _collect_images(images_dir)
    n_frames = len(frames)

    n_rej_blur, n_rej_dup = _collect_rejected(run_dir)
    if layer2_stats:
        reasons = layer2_stats.get("reject_reasons", {})
        n_rej_blur = sum(1 for v in reasons.values() if "blur" in v)
        n_rej_dup  = sum(1 for v in reasons.values() if "duplicate" in v)
        n_rej_exp  = sum(1 for v in reasons.values() if "exposure" in v)
        n_rej_stat = sum(1 for v in reasons.values() if "static" in v)
    else:
        n_rej_exp = n_rej_stat = 0

    if verbose:
        print(f"[Layer 3] Analyzing {n_frames} frames…")

    motion   = analyze_motion_sequence(frames)
    texture  = analyze_texture(frames)
    lighting = analyze_lighting(frames)
    coverage = estimate_coverage(motion)

    issues = classify_issues(
        n_frames=n_frames,
        motion=motion,
        texture=texture,
        lighting=lighting,
        coverage=coverage,
        layer2=layer2_stats or {},
    )

    n_critical = sum(1 for i in issues if i["severity"] == "critical")
    n_warnings = sum(1 for i in issues if i["severity"] == "warning")
    n_info     = sum(1 for i in issues if i["severity"] == "info")
    qs         = _quality_score(issues)
    readiness  = _colmap_readiness(qs, issues)
    rec        = _recommendation(readiness, issues)

    audit = {
        "audit_schema_version": 1,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "run_id": run_dir.name,
        "frame_inventory": {
            "n_frames_kept": n_frames,
            "n_rejected_blur": n_rej_blur,
            "n_rejected_duplicate": n_rej_dup,
            "n_rejected_exposure": n_rej_exp,
            "n_rejected_static": n_rej_stat,
            "total_input": n_frames + n_rej_blur + n_rej_dup + n_rej_exp + n_rej_stat,
        },
        "motion": {k: v for k, v in motion.items() if k != "pair_records"},
        "motion_pair_records": motion.get("pair_records", []),
        "texture": {k: v for k, v in texture.items() if k != "frame_scores"},
        "texture_frame_scores": texture.get("frame_scores", []),
        "lighting": {k: v for k, v in lighting.items() if k != "frame_data"},
        "lighting_frame_data": lighting.get("frame_data", []),
        "coverage": coverage,
        "issues": issues,
        "summary": {
            "quality_score": qs,
            "colmap_readiness": readiness,
            "n_critical": n_critical,
            "n_warnings": n_warnings,
            "n_info": n_info,
            "recommendation": rec,
        },
    }

    out_path = meta_dir / "layer3_audit.json"
    out_path.write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")

    if verbose:
        _print_console_report(audit, verbose=verbose)
        print(f"[Layer 3] Audit report → {out_path}")

    if halt_on_critical and n_critical > 0:
        crit_titles = [i["title"] for i in issues if i["severity"] == "critical"]
        raise RuntimeError(
            f"Layer 3 halted pipeline: {n_critical} critical issue(s): "
            + "; ".join(crit_titles)
        )

    return audit
