"""
Layer 6 — Issue Classifier.

Reads all upstream analysis results (ply, coverage, render, depth) and
produces a structured list of issues — each with:
  code        : machine-readable identifier (e.g. FLOATER_GAUSSIANS)
  severity    : CRITICAL | WARNING | INFO
  confidence  : 0.0 – 1.0 (how certain the detector is)
  detail      : human-readable one-liner
  fix         : concrete suggestion for the user
  metric      : the key metric that fired
  value       : the actual metric value
  threshold   : the threshold that was crossed
  spatial_hint: 3D centroid of the problem region (or None)
  nlp_data    : structured dict for the future NLP layer

This mirrors the Layer 3 pattern exactly so both can be consumed by the
same NLP explainer.
"""
from __future__ import annotations

from typing import Any


# ── Thresholds ────────────────────────────────────────────────────────────────

_FLOATER_FRAC_WARN     = 0.05   # 5 % of Gaussians are floaters → warning
_FLOATER_FRAC_CRIT     = 0.15   # 15 % → critical
_OVERSIZED_FRAC_WARN   = 0.10   # 10 % of Gaussians are oversized (>5 % scene dia)
_OVERSIZED_FRAC_CRIT   = 0.25
_LOW_OPACITY_FRAC_WARN = 0.30   # 30 % near-transparent (opacity < 0.1) → warning
_LOW_OPACITY_FRAC_CRIT = 0.60
_WEAK_COVERAGE_WARN    = 0.20   # 20 % of Gaussians seen by ≤2 cameras → warning
_WEAK_COVERAGE_CRIT    = 0.40
_UNSEEN_FRAC_WARN      = 0.05   # 5 % of Gaussians unseen (= hallucinated) → warning
_UNSEEN_FRAC_CRIT      = 0.15
_PSNR_GOOD             = 30.0   # dB — standard threshold for "good" reconstruction
_PSNR_WARN             = 25.0
_PSNR_CRIT             = 20.0
_SSIM_WARN             = 0.80
_SSIM_CRIT             = 0.65
_DEPTH_MISMATCH_WARN   = 0.15   # 15 % of Gaussians at wrong depth → warning
_DEPTH_MISMATCH_CRIT   = 0.35
_SPARSE_REGION_WARN    = 0.60   # 60 % of voxels empty → sparse scene
_SPARSE_REGION_CRIT    = 0.80


def _issue(
    code: str,
    severity: str,
    confidence: float,
    detail: str,
    fix: str,
    metric: str,
    value: float,
    threshold: float,
    spatial_hint: list[float] | None = None,
    extra_nlp: dict | None = None,
) -> dict:
    return {
        "code":         code,
        "severity":     severity,
        "confidence":   round(confidence, 3),
        "detail":       detail,
        "fix":          fix,
        "metric":       metric,
        "value":        round(float(value), 5),
        "threshold":    round(float(threshold), 5),
        "spatial_hint": spatial_hint,
        "nlp_data": {
            "issue_type":   code,
            "key_metric":   metric,
            "key_value":    round(float(value), 5),
            "threshold":    round(float(threshold), 5),
            "severity":     severity,
            "spatial_hint": spatial_hint,
            **(extra_nlp or {}),
        },
    }


def classify_issues(
    ply:      dict,
    coverage: dict,
    render:   dict,
    depth:    dict,
) -> list[dict]:
    """
    Run all detectors and return a list of issue dicts sorted by severity.
    """
    issues: list[dict] = []

    # ── 1. Floater Gaussians (PLY) ────────────────────────────────────────────
    if ply.get("ok") and ply.get("floater_stats"):
        fs  = ply["floater_stats"]
        frac = fs["fraction"]
        if frac >= _FLOATER_FRAC_CRIT:
            sev, conf = "CRITICAL", min(1.0, frac / _FLOATER_FRAC_CRIT)
        elif frac >= _FLOATER_FRAC_WARN:
            sev, conf = "WARNING", min(0.9, frac / _FLOATER_FRAC_CRIT)
        else:
            sev = conf = None

        if sev:
            issues.append(_issue(
                code="FLOATER_GAUSSIANS",
                severity=sev,
                confidence=conf,
                detail=(
                    f"{frac*100:.1f}% of Gaussians are statistical outliers far from "
                    f"the scene (>{fs['distance_threshold']:.2f} units from centroid)."
                ),
                fix=(
                    "Lower --growth-grad-threshold during training to reduce aggressive "
                    "densification. Add --no-sky-masks=False to block sky floaters. "
                    "Improve camera coverage of peripheral regions."
                ),
                metric="floater_fraction",
                value=frac,
                threshold=_FLOATER_FRAC_WARN,
                spatial_hint=ply.get("centroid"),
            ))

    # ── 2. Oversized Gaussians (underconstrained regions) ─────────────────────
    if ply.get("ok") and ply.get("scale_stats"):
        ss   = ply["scale_stats"]
        frac = ss["fraction_oversized"]
        if frac >= _OVERSIZED_FRAC_CRIT:
            sev, conf = "CRITICAL", min(1.0, frac / _OVERSIZED_FRAC_CRIT)
        elif frac >= _OVERSIZED_FRAC_WARN:
            sev, conf = "WARNING", min(0.9, frac / _OVERSIZED_FRAC_CRIT)
        else:
            sev = conf = None

        if sev:
            p95 = ss["relative_to_scene"]["p95_max_scale_frac"]
            issues.append(_issue(
                code="OVERSIZED_GAUSSIANS",
                severity=sev,
                confidence=conf,
                detail=(
                    f"{frac*100:.1f}% of Gaussians are >5% of scene diameter. "
                    f"P95 scale fraction = {p95:.3f}. "
                    "These are underconstrained regions where Brush grew large blobs."
                ),
                fix=(
                    "Capture more frames in areas with fewer camera views. "
                    "Use a tighter --growth-select-fraction to slow densification. "
                    "Ensure DPT depth maps were used for dense initialisation."
                ),
                metric="fraction_oversized",
                value=frac,
                threshold=_OVERSIZED_FRAC_WARN,
            ))

    # ── 3. Low-opacity Gaussians (uncertain / foggy regions) ──────────────────
    if ply.get("ok") and ply.get("opacity_stats"):
        ops  = ply["opacity_stats"]
        frac = ops["fraction_below_01"]
        if frac >= _LOW_OPACITY_FRAC_CRIT:
            sev, conf = "CRITICAL", 0.85
        elif frac >= _LOW_OPACITY_FRAC_WARN:
            sev, conf = "WARNING", 0.70
        else:
            sev = conf = None

        if sev:
            issues.append(_issue(
                code="LOW_OPACITY_ZONE",
                severity=sev,
                confidence=conf,
                detail=(
                    f"{frac*100:.1f}% of Gaussians have opacity < 0.1 — nearly invisible. "
                    "Large numbers indicate uncertain geometry (foggy/floaty appearance)."
                ),
                fix=(
                    "These are usually pruned by Brush during densification. "
                    "Increasing training steps (quality preset) often removes them. "
                    "Consider adding more training data for those regions."
                ),
                metric="fraction_opacity_below_01",
                value=frac,
                threshold=_LOW_OPACITY_FRAC_WARN,
            ))

    # ── 4. Sparse region (density map) ────────────────────────────────────────
    if ply.get("ok") and ply.get("density_map"):
        dm   = ply["density_map"]
        efrac = dm["empty_voxel_fraction"]
        if efrac >= _SPARSE_REGION_CRIT:
            sev, conf = "CRITICAL", 0.80
        elif efrac >= _SPARSE_REGION_WARN:
            sev, conf = "WARNING", 0.65
        else:
            sev = conf = None

        if sev:
            issues.append(_issue(
                code="SPARSE_REGION",
                severity=sev,
                confidence=conf,
                detail=(
                    f"{efrac*100:.1f}% of scene voxels have no Gaussians. "
                    "Parts of the scene have almost no geometry."
                ),
                fix=(
                    "Film those regions more carefully — walk through them slowly. "
                    "Check if COLMAP registered those views (look at sparse/0/ point cloud). "
                    "If COLMAP failed on those frames, see Layer 3 audit for root cause."
                ),
                metric="empty_voxel_fraction",
                value=efrac,
                threshold=_SPARSE_REGION_WARN,
            ))

    # ── 5. Weak camera coverage ────────────────────────────────────────────────
    if coverage.get("ok") and coverage.get("visibility_stats"):
        vs   = coverage["visibility_stats"]
        frac = vs["weak_fraction"]
        ufrac = vs["unseen_fraction"]

        if ufrac >= _UNSEEN_FRAC_CRIT:
            issues.append(_issue(
                code="UNSEEN_GAUSSIANS",
                severity="CRITICAL",
                confidence=min(1.0, ufrac / _UNSEEN_FRAC_CRIT),
                detail=(
                    f"{ufrac*100:.1f}% of Gaussians are outside ALL camera frustums. "
                    "These are hallucinated — Brush invented geometry no camera ever saw."
                ),
                fix=(
                    "These are floaters formed in sky/background behind cameras. "
                    "Enable sky masks (--no-sky-masks False). "
                    "Check camera registration — some cameras may be pointing the wrong way."
                ),
                metric="unseen_fraction",
                value=ufrac,
                threshold=_UNSEEN_FRAC_CRIT,
                spatial_hint=coverage.get("weak_zone", {}) and
                             coverage["weak_zone"].get("centroid"),
            ))
        elif ufrac >= _UNSEEN_FRAC_WARN:
            issues.append(_issue(
                code="UNSEEN_GAUSSIANS",
                severity="WARNING",
                confidence=0.70,
                detail=f"{ufrac*100:.1f}% of Gaussians unseen by any camera.",
                fix="Enable sky masks; check camera registration quality.",
                metric="unseen_fraction",
                value=ufrac,
                threshold=_UNSEEN_FRAC_WARN,
            ))

        if frac >= _WEAK_COVERAGE_CRIT:
            sev, conf = "CRITICAL", min(1.0, frac / _WEAK_COVERAGE_CRIT)
        elif frac >= _WEAK_COVERAGE_WARN:
            sev, conf = "WARNING", min(0.9, frac / _WEAK_COVERAGE_CRIT)
        else:
            sev = conf = None

        if sev:
            wz = coverage.get("weak_zone")
            spatial = wz["centroid"] if wz else None
            issues.append(_issue(
                code="WEAK_CAMERA_COVERAGE",
                severity=sev,
                confidence=conf,
                detail=(
                    f"{frac*100:.1f}% of Gaussians seen by ≤2 cameras — "
                    "underconstrained reconstruction. "
                    f"Mean visibility: {vs['mean_visibility']:.1f} cameras/Gaussian."
                ),
                fix=(
                    "Film areas with more overlap — walk slower through sparse zones. "
                    "Add side-angle shots for poorly covered regions. "
                    "Consider enabling exhaustive COLMAP matching for small frame sets."
                ),
                metric="weak_coverage_fraction",
                value=frac,
                threshold=_WEAK_COVERAGE_WARN,
                spatial_hint=spatial,
            ))

    # ── 6. Render quality — PSNR ──────────────────────────────────────────────
    if render.get("ok") and render.get("global_stats"):
        gs   = render["global_stats"]
        psnr = gs["psnr"]["mean"]
        ssim = gs["ssim"]["mean"]

        if psnr < _PSNR_CRIT:
            sev, conf = "CRITICAL", 0.95
        elif psnr < _PSNR_WARN:
            sev, conf = "WARNING", 0.85
        elif psnr < _PSNR_GOOD:
            sev, conf = "INFO", 0.70
        else:
            sev = conf = None

        if sev:
            worst5 = gs.get("worst_5_views", [])
            issues.append(_issue(
                code="TRAINING_UNDERFIT" if psnr < _PSNR_WARN else "RENDER_QUALITY_LOW",
                severity=sev,
                confidence=conf,
                detail=(
                    f"Mean PSNR = {psnr:.1f} dB (good ≥ 30 dB), "
                    f"SSIM = {ssim:.3f}. "
                    f"Worst views: {', '.join(worst5[:3])}."
                ),
                fix=(
                    "Increase training steps — use 'standard' (30k) or 'quality' (100k) preset. "
                    "Enable LPIPS loss (quality preset) for perceptual sharpness. "
                    "Check Layer 3 audit for dataset quality issues."
                ),
                metric="mean_psnr_db",
                value=psnr,
                threshold=_PSNR_GOOD,
                extra_nlp={"worst_views": worst5},
            ))

        # SSIM check (only if PSNR was OK — avoids duplicate issues)
        if sev is None and ssim < _SSIM_WARN:
            issues.append(_issue(
                code="RENDER_SSIM_LOW",
                severity="WARNING" if ssim < _SSIM_CRIT else "INFO",
                confidence=0.75,
                detail=(
                    f"SSIM = {ssim:.3f} (good ≥ 0.85). "
                    "Structure in rendered views doesn't match source well — "
                    "blurry textures or geometric errors."
                ),
                fix=(
                    "Add LPIPS loss weight (quality preset: --lpips-loss-weight 0.05). "
                    "Ensure training converged — check if more steps improve SSIM."
                ),
                metric="mean_ssim",
                value=ssim,
                threshold=_SSIM_WARN,
            ))

    # ── 7. High per-view render error (worst views) ───────────────────────────
    if render.get("ok") and render.get("per_view_metrics"):
        pv = render["per_view_metrics"]
        if pv:
            worst_psnr = pv[0]["psnr_db"]   # sorted worst→best already
            if worst_psnr < _PSNR_WARN:
                issues.append(_issue(
                    code="HIGH_RENDER_ERROR",
                    severity="WARNING",
                    confidence=0.85,
                    detail=(
                        f"Worst view '{pv[0]['stem']}' PSNR = {worst_psnr:.1f} dB. "
                        f"Top-3 worst: {', '.join(v['stem'] for v in pv[:3])}."
                    ),
                    fix=(
                        "These camera positions have high reconstruction error. "
                        "Film those zones with more coverage. "
                        "Check if those frames passed Layer 2 quality filtering (blur/exposure)."
                    ),
                    metric="worst_view_psnr_db",
                    value=worst_psnr,
                    threshold=_PSNR_WARN,
                    extra_nlp={"worst_stems": [v["stem"] for v in pv[:5]]},
                ))

    # ── 8. Depth mismatch ─────────────────────────────────────────────────────
    if depth.get("ok") and depth.get("global_mismatch_fraction") is not None:
        frac = depth["global_mismatch_fraction"]
        if frac >= _DEPTH_MISMATCH_CRIT:
            sev, conf = "CRITICAL", min(1.0, frac / _DEPTH_MISMATCH_CRIT)
        elif frac >= _DEPTH_MISMATCH_WARN:
            sev, conf = "WARNING", min(0.9, frac / _DEPTH_MISMATCH_CRIT)
        else:
            sev = conf = None

        if sev:
            worst_cams = [c["image_name"] for c in depth.get("worst_cameras", [])[:3]]
            issues.append(_issue(
                code="DEPTH_MISMATCH",
                severity=sev,
                confidence=conf,
                detail=(
                    f"{frac*100:.1f}% of Gaussians are at significantly wrong depth "
                    f"compared to DPT maps. "
                    f"Worst cameras: {', '.join(worst_cams)}."
                ),
                fix=(
                    "Gaussians forming at wrong depth indicate DPT-COLMAP scale "
                    "misalignment. Re-run with --dense-init-samples higher (4000+) "
                    "for better scale alignment. Check that DPT model is DPT_Large."
                ),
                metric="depth_mismatch_fraction",
                value=frac,
                threshold=_DEPTH_MISMATCH_WARN,
                extra_nlp={"worst_cameras": worst_cams},
            ))

    # ── Sort: CRITICAL first, then WARNING, then INFO ─────────────────────────
    order = {"CRITICAL": 0, "WARNING": 1, "INFO": 2}
    issues.sort(key=lambda x: (order.get(x["severity"], 3), -x["confidence"]))

    return issues


def compute_quality_grade(issues: list[dict], render: dict) -> str:
    """
    EXCELLENT / GOOD / FAIR / POOR / FAILED  based on issue profile + PSNR.
    """
    n_critical = sum(1 for i in issues if i["severity"] == "CRITICAL")
    n_warning  = sum(1 for i in issues if i["severity"] == "WARNING")

    psnr_mean: float | None = None
    if render.get("ok") and render.get("global_stats"):
        psnr_mean = render["global_stats"]["psnr"]["mean"]

    if n_critical >= 2:
        return "FAILED"
    if n_critical == 1:
        return "POOR"
    if n_warning >= 3:
        return "POOR"
    if n_warning >= 1:
        if psnr_mean is not None and psnr_mean < _PSNR_WARN:
            return "POOR"
        return "FAIR"
    if psnr_mean is not None:
        if psnr_mean >= _PSNR_GOOD:
            return "EXCELLENT"
        if psnr_mean >= _PSNR_WARN:
            return "GOOD"
        return "FAIR"
    # No render data — grade on structural issues only
    return "GOOD" if not issues else "FAIR"
