#!/usr/bin/env python3
"""
Issue classifier — Layer 3.

Converts raw analyzer metrics into structured issues.

Every issue has:
  code            — machine-readable unique identifier
  severity        — "critical" | "warning" | "info"
  confidence      — [0,1] how certain we are (based on metric strength)
  title           — one line summary
  detail          — 2-3 sentence technical explanation
  metrics         — the raw numbers that triggered this
  suggested_fix   — actionable instruction for a non-photographer user
  colmap_impact   — "critical" | "high" | "medium" | "low"
  splat_impact    — "critical" | "high" | "medium" | "low"
  nlp_data        — structured slot-fills for NLP sentence generation
                    (keys: issue_type, key_metric, key_value, thresholds, template_vars)

These are the raw training examples for a future NLP layer that explains
issues in plain English.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict, field
from typing import Any


@dataclass
class Issue:
    code: str
    severity: str            # critical / warning / info
    confidence: float
    title: str
    detail: str
    metrics: dict[str, Any]
    suggested_fix: str
    colmap_impact: str       # critical / high / medium / low
    splat_impact: str
    nlp_data: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict:
        return asdict(self)


# ── Individual issue detectors ────────────────────────────────────────────────

def _check_rotation_in_place(motion: dict) -> Issue | None:
    rot = motion.get("median_rotation_fraction", 0.5)
    trans = motion.get("median_translation_px", 0.0)
    if rot < 0.60:
        return None
    severity = "critical" if rot > 0.80 else "warning"
    confidence = min(1.0, (rot - 0.60) / 0.35)
    return Issue(
        code="ROTATION_IN_PLACE",
        severity=severity,
        confidence=round(confidence, 2),
        title="Camera is mostly rotating in place",
        detail=(
            f"{rot*100:.0f}% of inter-frame motion is rotational "
            f"(median translation only {trans:.1f}px). "
            "COLMAP needs camera baseline — physical translation around the subject — "
            "to triangulate 3D point depth. "
            "A camera spinning on its axis gives near-zero baseline and produces "
            "degenerate or flat reconstructions."
        ),
        metrics={"rotation_fraction": rot, "median_translation_px": trans},
        suggested_fix=(
            "Walk your feet in a circle around the object while keeping it centred "
            "in frame. Do NOT pivot at the hips or swivel your wrists. "
            "The camera should orbit the scene, not spin in one spot."
        ),
        colmap_impact="critical",
        splat_impact="critical",
        nlp_data={
            "issue_type": "motion",
            "key_metric": "rotation_fraction",
            "key_value": rot,
            "thresholds": {"critical": 0.80, "warning": 0.60},
            "template_vars": {
                "rot_pct": f"{rot*100:.0f}%",
                "trans_px": f"{trans:.1f}",
            },
        },
    )


def _check_insufficient_translation(motion: dict) -> Issue | None:
    trans = motion.get("median_translation_px", 0.0)
    static_frac = motion.get("static_pair_fraction", 0.0)
    if trans > 15.0 or static_frac < 0.25:
        return None
    severity = "critical" if static_frac > 0.6 else "warning"
    return Issue(
        code="INSUFFICIENT_MOTION",
        severity=severity,
        confidence=round(min(1.0, static_frac / 0.7), 2),
        title="Too little camera movement between frames",
        detail=(
            f"{static_frac*100:.0f}% of frame pairs show <4px of translation. "
            "This means the camera barely moved between retained frames. "
            "COLMAP needs sufficient baseline to estimate depth — without it, "
            "triangulation is numerically unstable and produces noisy point clouds."
        ),
        metrics={"static_pair_fraction": static_frac, "median_translation_px": trans},
        suggested_fix=(
            "Move the camera more deliberately and continuously while capturing. "
            "Each step should visibly shift the scene in frame. "
            "Avoid pausing the video while holding still."
        ),
        colmap_impact="high",
        splat_impact="high",
        nlp_data={
            "issue_type": "motion",
            "key_metric": "static_pair_fraction",
            "key_value": static_frac,
            "thresholds": {"critical": 0.60, "warning": 0.25},
            "template_vars": {"static_pct": f"{static_frac*100:.0f}%"},
        },
    )


def _check_low_coverage(coverage: dict) -> Issue | None:
    completeness = coverage.get("coverage_completeness", 1.0)
    uncovered = coverage.get("uncovered_sectors", [])
    traj = coverage.get("trajectory_type", "orbital")
    if completeness > 0.5 or not uncovered:
        return None
    n_covered = coverage.get("n_covered_sectors", 8)
    severity = "critical" if completeness < 0.25 else "warning"
    unc_str = ", ".join(uncovered)
    return Issue(
        code="INCOMPLETE_COVERAGE",
        severity=severity,
        confidence=round(min(1.0, (0.5 - completeness) / 0.4), 2),
        title=f"Scene not covered from all directions ({n_covered}/8 sectors)",
        detail=(
            f"Camera movement only covers {n_covered} of 8 directional sectors. "
            f"Missing directions: {unc_str}. "
            "Gaussian splatting needs views from all around the scene to fill in geometry. "
            "Uncovered sides appear as floaters or holes in the final splat."
        ),
        metrics={"coverage_completeness": completeness, "uncovered_sectors": uncovered},
        suggested_fix=(
            f"You are missing coverage from the {unc_str} side(s). "
            "Walk a full 360° circle around the subject. "
            "Also capture high and low angles (tilt up/down) for vertical coverage."
        ),
        colmap_impact="high",
        splat_impact="critical",
        nlp_data={
            "issue_type": "coverage",
            "key_metric": "coverage_completeness",
            "key_value": completeness,
            "thresholds": {"critical": 0.25, "warning": 0.50},
            "template_vars": {
                "n_covered": str(n_covered),
                "uncovered": unc_str,
            },
        },
    )


def _check_linear_trajectory(coverage: dict, motion: dict) -> Issue | None:
    traj = coverage.get("trajectory_type", "orbital")
    resultant = motion.get("mean_resultant_length", 0.0)
    if traj != "linear" or resultant < 0.65:
        return None
    ang = motion.get("dominant_direction_deg", 0.0)
    dir_name = _angle_to_compass(ang)
    return Issue(
        code="LINEAR_TRAJECTORY",
        severity="warning",
        confidence=round(min(1.0, (resultant - 0.65) / 0.35), 2),
        title="Camera moved in a straight line rather than orbiting",
        detail=(
            f"Camera trajectory is predominantly linear ({dir_name} direction). "
            "This creates a one-sided reconstruction — geometry seen from only one direction. "
            "The opposite side of the scene will be missing or reconstructed from very few views."
        ),
        metrics={"mean_resultant_length": resultant, "dominant_direction_deg": ang},
        suggested_fix=(
            "Instead of walking past the object, walk around it. "
            "Keep the subject centred in frame and complete at least one full orbit."
        ),
        colmap_impact="medium",
        splat_impact="high",
        nlp_data={
            "issue_type": "coverage",
            "key_metric": "mean_resultant_length",
            "key_value": resultant,
            "thresholds": {"warning": 0.65},
            "template_vars": {"direction": dir_name},
        },
    )


def _check_unstable_lighting(lighting: dict) -> Issue | None:
    cv = lighting.get("brightness", {}).get("cv", 0.0)
    n_jumps = lighting.get("exposure_jumps", {}).get("count", 0)
    n_frames = max(lighting.get("n_frames", 1), 1)
    jump_frac = n_jumps / n_frames
    stability = lighting.get("lighting_stability_score", 1.0)

    if cv < 0.12 and jump_frac < 0.05:
        return None

    severity = "critical" if cv > 0.25 or jump_frac > 0.15 else "warning"
    jump_names = lighting.get("exposure_jumps", {}).get("jump_frame_names", [])[:5]

    return Issue(
        code="UNSTABLE_LIGHTING",
        severity=severity,
        confidence=round(min(1.0, max(cv / 0.3, jump_frac / 0.2)), 2),
        title="Brightness fluctuates significantly across frames",
        detail=(
            f"Brightness coefficient of variation is {cv:.2f} "
            f"(ideal <0.10), with {n_jumps} sudden exposure jumps. "
            "Phone auto-exposure adjusts brightness between frames, creating "
            "colour/brightness inconsistency. "
            "3DGS assumes the same surface looks the same brightness from every view — "
            "lighting variation breaks this assumption and creates colour artefacts."
        ),
        metrics={"brightness_cv": cv, "n_exposure_jumps": n_jumps, "jump_frame_sample": jump_names},
        suggested_fix=(
            "Lock camera exposure before recording: on iOS tap and hold on screen to "
            "lock AE/AF, then slide brightness to mid-range. "
            "On Android use Pro mode and fix ISO + shutter speed. "
            "Avoid moving from bright to dark areas during capture."
        ),
        colmap_impact="low",
        splat_impact="high",
        nlp_data={
            "issue_type": "lighting",
            "key_metric": "brightness_cv",
            "key_value": cv,
            "thresholds": {"critical": 0.25, "warning": 0.12},
            "template_vars": {"cv_pct": f"{cv*100:.0f}%", "n_jumps": str(n_jumps)},
        },
    )


def _check_white_balance_drift(lighting: dict) -> Issue | None:
    drift = lighting.get("color_temperature", {}).get("drift_score", 0.0)
    if drift < 0.06:
        return None
    severity = "warning" if drift < 0.15 else "critical"
    return Issue(
        code="WHITE_BALANCE_DRIFT",
        severity=severity,
        confidence=round(min(1.0, drift / 0.2), 2),
        title="White balance shifts between frames",
        detail=(
            f"R/G ratio standard deviation is {drift:.3f} across frames "
            "(ideal <0.05). Phone auto-white-balance changes the colour cast "
            "between frames — warm near windows, cool under LED lights. "
            "In 3DGS each Gaussian stores a colour, so drifting white balance "
            "causes the same surface to render differently depending on viewing angle."
        ),
        metrics={"RG_std": drift},
        suggested_fix=(
            "Lock white balance before recording. On iOS: use a third-party app "
            "(e.g. Halide, ProCamera) to fix white balance. "
            "On Android Pro mode: set manual white balance (e.g. 5500K daylight). "
            "Alternatively, expose-normalise frames in post using Layer 3b (coming)."
        ),
        colmap_impact="low",
        splat_impact="medium",
        nlp_data={
            "issue_type": "lighting",
            "key_metric": "RG_std",
            "key_value": drift,
            "thresholds": {"critical": 0.15, "warning": 0.06},
            "template_vars": {"drift": f"{drift:.3f}"},
        },
    )


def _check_low_texture(texture: dict) -> Issue | None:
    frac = texture.get("low_texture_fraction", 0.0)
    kp_mean = texture.get("keypoint_density", {}).get("mean", 100.0)
    if frac < 0.15 and kp_mean > 30:
        return None
    severity = "critical" if frac > 0.40 or kp_mean < 15 else "warning"
    names = texture.get("low_texture_frame_names", [])[:6]
    return Issue(
        code="LOW_TEXTURE_FRAMES",
        severity=severity,
        confidence=round(min(1.0, max(frac / 0.5, (30 - kp_mean) / 30)), 2),
        title=f"{frac*100:.0f}% of frames have too few distinctive features",
        detail=(
            f"{frac*100:.0f}% of frames fall in the lowest texture quartile "
            f"(mean FAST keypoints: {kp_mean:.0f}/frame). "
            "COLMAP extracts SIFT features — if frames show blank walls, sky, "
            "reflective surfaces, or out-of-focus backgrounds, there are no keypoints "
            "to match. Those frames contribute no geometry and may confuse matching."
        ),
        metrics={
            "low_texture_fraction": frac,
            "mean_keypoints": kp_mean,
            "sample_frames": names,
        },
        suggested_fix=(
            "Ensure the scene has visible texture: rough surfaces, patterns, objects. "
            "Avoid pointing the camera at blank walls, bright windows, or mirror surfaces. "
            "If capturing an object, place it on a textured surface (e.g. a rug, not a white table)."
        ),
        colmap_impact="high",
        splat_impact="medium",
        nlp_data={
            "issue_type": "texture",
            "key_metric": "low_texture_fraction",
            "key_value": frac,
            "thresholds": {"critical": 0.40, "warning": 0.15},
            "template_vars": {"pct": f"{frac*100:.0f}%", "kp": f"{kp_mean:.0f}"},
        },
    )


def _check_poor_overlap(coverage: dict) -> Issue | None:
    overlap = coverage.get("frame_overlap_score", 0.8)
    # Ideal: 0.50–0.85. Below 0.40 = too sparse. Above 0.90 = could dedup more.
    if overlap >= 0.40:
        return None
    return Issue(
        code="POOR_FRAME_OVERLAP",
        severity="warning",
        confidence=round(min(1.0, (0.40 - overlap) / 0.3), 2),
        title="Consecutive frames may not overlap enough for reliable matching",
        detail=(
            f"Estimated mean frame overlap is {overlap:.2f} ({overlap*100:.0f}%). "
            "COLMAP sequential matching requires ~50–85% overlap between adjacent frames "
            "to find common keypoints reliably. "
            "Too little overlap means features disappear between frames and the "
            "image graph may become disconnected."
        ),
        metrics={"frame_overlap_score": overlap},
        suggested_fix=(
            "Move the camera more slowly, or increase the number of frames extracted "
            "from the video. "
            "In the pipeline, increase --max-frames or decrease --hamming-threshold "
            "to keep more frames."
        ),
        colmap_impact="high",
        splat_impact="medium",
        nlp_data={
            "issue_type": "coverage",
            "key_metric": "frame_overlap_score",
            "key_value": overlap,
            "thresholds": {"warning": 0.40},
            "template_vars": {"overlap_pct": f"{overlap*100:.0f}%"},
        },
    )


def _check_low_parallax(coverage: dict) -> Issue | None:
    parallax = coverage.get("parallax_score", 0.5)
    if parallax >= 0.30:
        return None
    return Issue(
        code="LOW_PARALLAX",
        severity="warning",
        confidence=round(min(1.0, (0.30 - parallax) / 0.25), 2),
        title="Low depth separation detected (weak parallax)",
        detail=(
            f"Parallax score is {parallax:.2f} (ideal >0.40). "
            "Parallax is the difference in apparent position of nearby vs far objects "
            "as the camera moves. Without parallax, COLMAP cannot estimate scene depth accurately. "
            "This happens when the camera is too far from the subject or moves too little."
        ),
        metrics={"parallax_score": parallax},
        suggested_fix=(
            "Move closer to the subject (within 0.5–3m for objects, 1–10m for rooms). "
            "Ensure the camera physically translates (not just rotates) by at least "
            "10–20cm between captured positions."
        ),
        colmap_impact="high",
        splat_impact="high",
        nlp_data={
            "issue_type": "motion",
            "key_metric": "parallax_score",
            "key_value": parallax,
            "thresholds": {"warning": 0.30},
            "template_vars": {"score": f"{parallax:.2f}"},
        },
    )


def _check_too_few_frames(n_frames: int, layer2: dict) -> Issue | None:
    if n_frames >= 30:
        return None
    severity = "critical" if n_frames < 15 else "warning"
    return Issue(
        code="TOO_FEW_FRAMES",
        severity=severity,
        confidence=1.0,
        title=f"Only {n_frames} frames remain after filtering",
        detail=(
            f"Only {n_frames} frames passed Layer 2 quality filters. "
            "COLMAP needs at least 20–30 frames for a stable reconstruction; "
            "below 15 it will almost certainly fail. "
            "More frames = more constraints = more accurate camera poses."
        ),
        metrics={"n_frames": n_frames},
        suggested_fix=(
            "Re-capture with a slower camera movement to generate more distinct frames. "
            "Alternatively, lower the Layer 2 hamming-threshold (e.g. --hamming-threshold 4) "
            "to keep more similar frames."
        ),
        colmap_impact="critical",
        splat_impact="critical",
        nlp_data={
            "issue_type": "quantity",
            "key_metric": "n_frames",
            "key_value": n_frames,
            "thresholds": {"critical": 15, "warning": 30},
            "template_vars": {"n": str(n_frames)},
        },
    )


def _check_no_loop_closure(coverage: dict, motion: dict) -> Issue | None:
    closed = coverage.get("loop_closed", False)
    traj = coverage.get("trajectory_type", "orbital")
    trans = motion.get("median_translation_px", 0.0)
    # Only raise this if there is substantial motion (not stationary)
    if closed or trans < 10.0 or traj == "stationary":
        return None
    loop_frac = coverage.get("loop_closure_fraction", 0.0)
    return Issue(
        code="NO_LOOP_CLOSURE",
        severity="info",
        confidence=0.6,
        title="Camera did not return to starting position (no loop closure)",
        detail=(
            f"End position is approximately {(1-loop_frac)*100:.0f}% of the capture "
            "diameter away from the start. "
            "Loop closure — where the camera visually revisits an earlier position — "
            "gives COLMAP an extra constraint that tightens the overall reconstruction. "
            "Without it, pose drift accumulates and the point cloud may be slightly warped."
        ),
        metrics={"loop_closure_fraction": loop_frac},
        suggested_fix=(
            "After orbiting the scene, return to where you started and record "
            "2–3 seconds of overlap with your opening frames before stopping."
        ),
        colmap_impact="medium",
        splat_impact="low",
        nlp_data={
            "issue_type": "coverage",
            "key_metric": "loop_closure_fraction",
            "key_value": loop_frac,
            "thresholds": {"info": 0.0},
            "template_vars": {"gap_pct": f"{(1-loop_frac)*100:.0f}%"},
        },
    )


def _check_dark_or_bright(lighting: dict) -> list[Issue]:
    issues = []
    n_dark = lighting.get("n_dark_frames", 0)
    n_over = lighting.get("n_overexposed_frames", 0)
    n = max(lighting.get("n_frames", 1), 1)

    if n_dark / n > 0.10:
        issues.append(Issue(
            code="DARK_FRAMES",
            severity="warning",
            confidence=round(min(1.0, (n_dark / n) / 0.3), 2),
            title=f"{n_dark} frames are too dark (L<30)",
            detail=(
                f"{n_dark} of {n} frames ({n_dark/n*100:.0f}%) are underexposed "
                "(mean lightness < 30/100). "
                "Dark frames have low SNR — COLMAP may fail to extract features "
                "and 3DGS will produce noisy colour estimation in those regions."
            ),
            metrics={"n_dark_frames": n_dark, "fraction": n_dark / n},
            suggested_fix=(
                "Increase ambient light or use the phone torch. "
                "Avoid capturing scenes with strong backlighting. "
                "On phones, tap on the subject to expose for it, then lock exposure."
            ),
            colmap_impact="medium",
            splat_impact="medium",
            nlp_data={
                "issue_type": "lighting",
                "key_metric": "dark_frame_fraction",
                "key_value": n_dark / n,
                "thresholds": {"warning": 0.10},
                "template_vars": {"n_dark": str(n_dark), "pct": f"{n_dark/n*100:.0f}%"},
            },
        ))

    if n_over / n > 0.10:
        issues.append(Issue(
            code="OVEREXPOSED_FRAMES",
            severity="warning",
            confidence=round(min(1.0, (n_over / n) / 0.3), 2),
            title=f"{n_over} frames are overexposed (L>88)",
            detail=(
                f"{n_over} of {n} frames ({n_over/n*100:.0f}%) are overexposed. "
                "Clipped highlights lose colour information — 3DGS cannot learn the "
                "correct colour for surfaces that appear blown-out."
            ),
            metrics={"n_overexposed_frames": n_over, "fraction": n_over / n},
            suggested_fix=(
                "Reduce exposure: on iPhone slide the sun icon down after tapping to focus. "
                "Move away from direct light sources or shoot in shade."
            ),
            colmap_impact="low",
            splat_impact="medium",
            nlp_data={
                "issue_type": "lighting",
                "key_metric": "overexposed_fraction",
                "key_value": n_over / n,
                "thresholds": {"warning": 0.10},
                "template_vars": {"n_over": str(n_over), "pct": f"{n_over/n*100:.0f}%"},
            },
        ))

    return issues


# ── Helpers ───────────────────────────────────────────────────────────────────

def _angle_to_compass(deg: float) -> str:
    directions = ["East", "NE", "North", "NW", "West", "SW", "South", "SE"]
    idx = int(((deg + 22.5) % 360) / 45) % 8
    return directions[idx]


# ── Main entry ────────────────────────────────────────────────────────────────

def classify_issues(
    *,
    n_frames: int,
    motion: dict,
    texture: dict,
    lighting: dict,
    coverage: dict,
    layer2: dict,
) -> list[dict]:
    """
    Run all detectors and return a list of issue dicts, sorted by severity.
    """
    raw: list[Issue | None] = [
        _check_too_few_frames(n_frames, layer2),
        _check_rotation_in_place(motion),
        _check_insufficient_translation(motion),
        _check_low_coverage(coverage),
        _check_linear_trajectory(coverage, motion),
        _check_poor_overlap(coverage),
        _check_low_parallax(coverage),
        _check_no_loop_closure(coverage, motion),
        _check_unstable_lighting(lighting),
        _check_white_balance_drift(lighting),
        _check_low_texture(texture),
        *_check_dark_or_bright(lighting),
    ]

    issues = [i.as_dict() for i in raw if i is not None]

    _sev_order = {"critical": 0, "warning": 1, "info": 2}
    issues.sort(key=lambda x: (_sev_order.get(x["severity"], 3), -x["confidence"]))
    return issues
