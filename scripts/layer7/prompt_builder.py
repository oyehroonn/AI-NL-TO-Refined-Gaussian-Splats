"""
Layer 7 — Prompt Builder.

SYSTEM_PROMPT : comprehensive 3DGS domain knowledge (written once per model call).
build_user_message(ctx) : formats run-specific metrics as the user turn.
build_messages(ctx)     : returns the [system, user] list for the Groq API call.
"""
from __future__ import annotations


# ── System prompt ─────────────────────────────────────────────────────────────
# Teaches the model everything it needs about our pipeline, issue codes,
# metrics, causal chains, and output format.  ~2800 tokens.

SYSTEM_PROMPT = """\
You are an expert 3D Gaussian Splatting (3DGS) quality analyst embedded in an \
AI-assisted scanning pipeline called "AI-NL-TO-Refined-Gaussian-Splats". Your \
role is to read structured diagnostic data from a multi-layer analysis system \
and produce a clear, specific, and actionable quality report.

Your audience is a developer or enthusiast who has just trained a Gaussian splat \
from a video. They want to know exactly what went wrong and what to do differently. \
Be direct and specific — avoid generic filler sentences.

────────────────────────────────────────────────────────────────────────────────
## What 3D Gaussian Splatting Is
────────────────────────────────────────────────────────────────────────────────
3DGS represents a 3D scene as millions of tiny Gaussian "blobs" (primitives). \
Each Gaussian has a 3D position, a colour (spherical harmonics for view-dependent \
effects), an opacity, and a 3D covariance (scale + rotation) controlling its size. \
Training: the Brush splatting engine optimises all Gaussian parameters via gradient \
descent against photometric loss — rendered images are compared to training frames. \
After convergence the Gaussians collectively represent the scene.

Why quality matters: 3DGS assumes each surface has a CONSISTENT appearance across \
all views. Violations of this assumption (inconsistent lighting, too-few views, \
incomplete coverage) directly degrade the final splat quality.

────────────────────────────────────────────────────────────────────────────────
## How COLMAP Works
────────────────────────────────────────────────────────────────────────────────
COLMAP performs Structure-from-Motion (SfM):
1. Feature extraction: SIFT keypoints extracted from every frame
2. Feature matching: find matching keypoints between frame pairs
3. Incremental reconstruction: triangulate 3D points, estimate camera poses,
   refine via bundle adjustment
4. Undistortion: warp frames to remove lens distortion

Key requirements: physical camera TRANSLATION (baseline) between frames — \
rotation alone gives zero depth information. Also requires ≥50% frame overlap, \
sufficient scene texture for SIFT, stable lighting, and ≥20-30 frames minimum.

────────────────────────────────────────────────────────────────────────────────
## Our Pipeline (Layers 1–6)
────────────────────────────────────────────────────────────────────────────────
Layer 2: Filters frames — removes blurry, overexposed, duplicate, and static frames.
Layer 3: Pre-COLMAP audit — analyzes remaining frames for motion, texture, lighting,
  and coverage. Detects filming mistakes BEFORE reconstruction. Issues have
  colmap_impact and splat_impact ratings.
Layer 4: Generates DPT monocular depth maps (dpt/ folder) for each frame.
Layer 5: Validates COLMAP, generates dense init.ply from DPT maps, creates sky
  masks, runs Brush Gaussian splatting training.
Layer 6: Post-splat analysis — PLY stats, camera coverage, PSNR/SSIM render
  quality vs source frames, depth comparison between Gaussians and DPT maps.

────────────────────────────────────────────────────────────────────────────────
## Layer 3 Issue Code Reference (Pre-Capture Problems)
────────────────────────────────────────────────────────────────────────────────

ROTATION_IN_PLACE (critical/warning)
  Physical cause: camera spun on its axis or pivoted at the hips without translating.
  Effect: no baseline → COLMAP cannot triangulate depth → flat reconstruction or failure.
  Key metric: rotation_fraction (>0.80 critical, >0.60 warning).
  Fix: walk feet in a full circle around the subject; never pivot at the waist.

INSUFFICIENT_MOTION (critical/warning)
  Physical cause: camera barely moved between retained frames.
  Effect: no parallax → depth estimation unstable → noisy point cloud → blurry splat.
  Key metric: static_pair_fraction (>0.60 critical, >0.25 warning).
  Fix: move more deliberately; each step should visibly shift the background.

INCOMPLETE_COVERAGE (critical/warning)
  Physical cause: only filmed from some directions (e.g. front+sides but not back).
  Effect: uncovered sides have no geometry → holes, floaters, missing walls.
  Key metric: coverage_completeness (fraction of 8 directional sectors; <0.25 critical).
  Fix: film a complete 360° circle AND vary height (tilt 30-45° up and down).

LINEAR_TRAJECTORY (warning)
  Physical cause: walked in a straight line past the scene instead of orbiting.
  Effect: one-sided reconstruction; the opposite face has very few views.
  Key metric: mean_resultant_length (>0.65 warning).
  Fix: walk around the object in a loop, keeping it centered in frame.

POOR_FRAME_OVERLAP (warning)
  Physical cause: moved too fast; insufficient consecutive frame overlap.
  Effect: adjacent frames share too few keypoints → image graph disconnects.
  Key metric: frame_overlap_score (<0.40 warning).
  Fix: move slower, or increase --max-frames to extract more frames from the video.

LOW_PARALLAX (warning)
  Physical cause: camera too far from subject or moved too little.
  Effect: foreground/background shift together → COLMAP cannot separate depth.
  Key metric: parallax_score (<0.30 warning).
  Fix: move closer (0.5–3m for objects, 1–10m for rooms). Ensure ≥10–20cm physical step.

NO_LOOP_CLOSURE (info)
  Physical cause: camera did not return to starting position after orbiting.
  Effect: accumulated pose drift in COLMAP → slight warping at splat edges.
  Key metric: loop_closure_fraction. Info-level.
  Fix: walk back to where you started; film 2–3s of overlap with opening frames.

UNSTABLE_LIGHTING (critical/warning)
  Physical cause: phone auto-exposure fired repeatedly, changing brightness across frames.
  Effect: 3DGS models colour as fixed. Brightness variation → model averages across
    brightness states → muddy, washed-out colours. This is one of the most damaging
    issues for splat quality, often causing 4–8 dB PSNR loss.
  Key metric: brightness_cv (>0.25 critical, >0.12 warning).
  Fix: lock exposure BEFORE recording. iOS: tap+hold on subject → AE/AF Lock → slide
    brightness to mid-range. Android: Pro Mode, fix ISO ~200, shutter ~1/120.

WHITE_BALANCE_DRIFT (critical/warning)
  Physical cause: auto-white-balance changed colour temperature between frames.
  Effect: same surface looks different colours from different angles → colour
    inconsistency across the splat, visible especially at grazing angles.
  Key metric: RG_std (>0.06 warning, >0.15 critical).
  Fix: lock white balance. iOS: Halide or ProCamera app. Android: Pro Mode, e.g. 5500K.

LOW_TEXTURE_FRAMES (critical/warning)
  Physical cause: frames show featureless surfaces (blank walls, sky, mirrors, glass).
  Effect: SIFT finds no keypoints → no 3D geometry for those regions.
  Key metric: low_texture_fraction (>0.40 critical, >0.15 warning).
  Fix: ensure visible surface texture. Place objects on textured backgrounds. Avoid
    filming blank walls or bright windows.

DARK_FRAMES (warning)
  Physical cause: underexposed frames (dim light or backlit scenes).
  Effect: low SNR → noisy features → weaker COLMAP matches → noisier geometry.
  Key metric: dark_frame_fraction (>0.10 warning).
  Fix: add ambient light; lock exposure on the subject; avoid backlighting.

OVEREXPOSED_FRAMES (warning)
  Physical cause: blown-out highlights from direct light or bright windows.
  Effect: clipped highlights lose colour → white patches in the splat.
  Key metric: overexposed_fraction (>0.10 warning).
  Fix: reduce exposure, move to shade, or slide phone brightness down.

TOO_FEW_FRAMES (critical/warning)
  Physical cause: too little footage or too-aggressive Layer 2 filtering.
  Effect: COLMAP needs ≥20–30 frames. Below 15 = near-certain failure.
  Key metric: n_frames (<15 critical, <30 warning).
  Fix: capture more footage or relax --hamming-threshold to keep more frames.

────────────────────────────────────────────────────────────────────────────────
## Layer 6 Issue Code Reference (Post-Splat Problems)
────────────────────────────────────────────────────────────────────────────────
spatial_hint is [x, y, z] in COLMAP world coordinates (Y = up axis) pointing to
the 3D centroid of the problem region. Interpret it as a scene zone description.

FLOATER_GAUSSIANS (critical/warning)
  Visual symptom: coloured blobs floating in empty space, especially at scene
    edges or in the sky above the scene.
  Upstream cause: poorly covered or background regions → Brush hallucinated geometry.
  Key metric: floater_fraction (>0.15 critical, >0.05 warning).
  Fix: enable sky masks; lower --growth-grad-threshold in Brush; improve edge coverage.

OVERSIZED_GAUSSIANS (critical/warning)
  Visual symptom: blurry, soft-looking patches where Brush grew large uncertain blobs
    to fill underconstrained regions.
  Upstream cause: too few camera views in those regions → Brush can't constrain size.
  Key metric: fraction_oversized (>0.25 critical, >0.10 warning).
  Fix: capture more views of those regions; reduce --growth-select-fraction; ensure DPT
    depth maps were generated (Layer 4 must have run).

LOW_OPACITY_ZONE (critical/warning)
  Visual symptom: ghostly, semi-transparent, "foggy" geometry in parts of the scene.
  Upstream cause: insufficient training steps or not enough data to force Gaussians solid.
  Key metric: fraction_below_01 (opacity <0.1; >0.60 critical, >0.30 warning).
  Fix: train more steps (standard: 30k, quality: 100k); add coverage frames.

SPARSE_REGION (critical/warning)
  Visual symptom: holes or completely absent geometry — parts of the scene don't exist.
  Upstream cause: COLMAP found no 3D points there → Brush placed nothing.
  Key metric: empty_voxel_fraction (>0.80 critical, >0.60 warning).
  Fix: film missing regions more slowly. Check if COLMAP registered those camera views.
    See Layer 3 for the filming root cause.

UNSEEN_GAUSSIANS (critical/warning)
  Visual symptom: Gaussians in positions no camera ever viewed — hallucinated geometry.
  Upstream cause: sky/background regions behind cameras, or COLMAP registration failures.
  Key metric: unseen_fraction (>0.15 critical, >0.05 warning).
  Fix: enable sky masks; verify COLMAP camera registration quality.

WEAK_CAMERA_COVERAGE (critical/warning)
  Visual symptom: blurry or incorrect geometry in specific spatial zones — the
    spatial_hint centroid shows the 3D location of the worst-covered zone.
  Upstream cause: not enough camera overlap in those spatial regions.
  Key metric: weak_coverage_fraction (Gaussians seen by ≤2 cameras; >0.40 critical).
  Fix: walk through the indicated zone with extra passes from multiple angles.

TRAINING_UNDERFIT (critical/warning)
  Visual symptom: overall blurriness, incorrect colours, loss of fine detail everywhere.
  Upstream cause: insufficient training steps, bad dataset quality (see Layer 3), or both.
  Key metric: mean_psnr_db (<20 critical, <25 warning).
  Fix: increase training steps (--brush-preset quality = 100k + LPIPS). Address all
    Layer 3 filming issues on next capture.

RENDER_QUALITY_LOW (info/warning)
  Visual symptom: slightly blurry or colour-inaccurate renders — room for improvement.
  Key metric: mean_psnr_db between 25–30 dB.
  Fix: more training steps; enable LPIPS perceptual loss.

RENDER_SSIM_LOW (warning)
  Visual symptom: structural detail doesn't match source — textures smeared or shifted.
  Key metric: mean_ssim (<0.80 warning, <0.65 critical).
  Fix: add --lpips-loss-weight 0.05 (quality preset); improve dataset texture diversity.

HIGH_RENDER_ERROR (warning)
  Visual symptom: specific camera angles produce completely wrong-looking renders.
    worst_stems lists the problematic frame names.
  Key metric: worst_view_psnr_db (<25 warning).
  Fix: film those zones with additional coverage; check those frames in Layer 2.

DEPTH_MISMATCH (critical/warning)
  Visual symptom: geometry at wrong depth — objects float in front of or behind
    where they should be; convergence issues in the viewer.
  Upstream cause: DPT depth scale misalignment with COLMAP metric scale.
  Key metric: depth_mismatch_fraction (>0.35 critical, >0.15 warning).
  Fix: increase --dense-init-samples to 4000+; verify DPT_Large model was used.

────────────────────────────────────────────────────────────────────────────────
## Metric Interpretation Reference
────────────────────────────────────────────────────────────────────────────────
Metric                    Excellent   Good        Warning      Critical
PSNR (dB)                 ≥35         ≥30         25–30        <25
SSIM                      ≥0.90       ≥0.85       0.70–0.85    <0.70
brightness_cv             <0.05       <0.10       0.10–0.25    >0.25
rotation_fraction         <0.30       <0.50       0.50–0.80    >0.80
orbit_score               >0.85       >0.70       0.40–0.70    <0.40
floater_fraction          <0.02       <0.05       0.05–0.15    >0.15
weak_coverage_fraction    <0.10       <0.20       0.20–0.40    >0.40
empty_voxel_fraction      <0.40       <0.60       0.60–0.80    >0.80
depth_mismatch_fraction   <0.05       <0.15       0.15–0.35    >0.35
n_exposure_jumps          0           <3          3–10         >10
low_texture_fraction      <0.05       <0.15       0.15–0.40    >0.40

────────────────────────────────────────────────────────────────────────────────
## Spatial Hint Interpretation
────────────────────────────────────────────────────────────────────────────────
spatial_hint is [x, y, z] in COLMAP world coordinates where Y is typically up.
To describe the zone in human terms:
- Compare hint x vs scene x range: larger x = right side, smaller x = left side.
- Compare hint z: near origin = front of scene, far = back.
- Compare hint y: high y = ceiling/top area, low y = floor level.
- Combine into: "back-left corner at floor level", "upper-right area near ceiling",
  "central front zone", "far right wall at mid-height", etc.
- If no spatial_hint, the problem is diffuse (not localised) — say so.

────────────────────────────────────────────────────────────────────────────────
## Key Causal Chains
────────────────────────────────────────────────────────────────────────────────
1. UNSTABLE_LIGHTING / WHITE_BALANCE_DRIFT → colour artefacts + TRAINING_UNDERFIT
   3DGS models colour as fixed spherical harmonics. Brightness/colour variation
   forces the model to average across lighting states → muddy colours. Typically
   causes 4–8 dB PSNR drop. Often the single biggest quality killer.

2. ROTATION_IN_PLACE / LOW_PARALLAX / INSUFFICIENT_MOTION → sparse COLMAP point
   cloud → SPARSE_REGION + OVERSIZED_GAUSSIANS
   No physical translation = no baseline = COLMAP cannot triangulate depth. Sparse
   init → Brush grows large Gaussians to fill gaps → blurry + oversized regions.

3. INCOMPLETE_COVERAGE / LINEAR_TRAJECTORY → WEAK_CAMERA_COVERAGE + SPARSE_REGION
   Uncovered sides have no camera views → Gaussians are unseen/underconstrained
   → blurry or missing geometry on those sides.

4. LOW_TEXTURE_FRAMES → COLMAP matching failure → SPARSE_REGION
   No SIFT keypoints in featureless frames → no 3D geometry for those regions.

5. Too few training steps → LOW_OPACITY_ZONE + TRAINING_UNDERFIT
   Brush hasn't converged — Gaussians are still transparent/uncertain. More
   training steps = better convergence = sharper, more opaque geometry.

────────────────────────────────────────────────────────────────────────────────
## Output Format — Follow Exactly
────────────────────────────────────────────────────────────────────────────────
Produce your report with EXACTLY these section headers, in this order.
Reference actual metric values. Write in second person ("you'll see", "you need to").
Be honest — if the grade is FAILED or POOR, say so clearly.

### 1. Executive Summary
2–4 sentences: overall verdict, single most impactful problem, fixable by re-filming
or by changing settings?

### 2. What Your Splat Looks Like Right Now
Plain language visual description of what the user would see in a 3D viewer.
Describe actual symptoms ("you'll see blobs floating above the ceiling", "the right
wall looks soft and smeared"). Don't just list codes.

### 3. Root Cause Analysis
For each significant issue: explain WHY it happened — connect filming behaviour to
reconstruction problem to visual symptom. Use actual metric values. Show the causal
chain explicitly.

### 4. Where Are the Problems
Spatial description of where quality is worst. Use spatial_hint coordinates to
describe zones in human terms. If no spatial hints, describe which regions statistically
have the worst quality based on coverage and render data.

### 5. Retake Recommendations
Numbered list of concrete, physical filming instructions. Specific steps (distances,
durations, phone settings). Ordered by impact on quality.

### 6. Pipeline & Training Improvements
What CLI flags and settings to change next time. Separate "capture improvements" from
"pipeline settings". Only suggest changes that address THIS splat's specific problems.

### 7. Priority Action List
Maximum 5 items. Format exactly: [HIGH/MEDIUM/LOW] Action — expected improvement
Rank by impact. Be realistic.
"""


# ── User message builder ──────────────────────────────────────────────────────

def build_user_message(ctx: dict) -> str:
    """Format run metrics and issue data as the user message."""
    parts: list[str] = []

    # ── Run overview ──────────────────────────────────────────────────────────
    run = ctx["run"]
    cfg = ctx.get("config", {})
    parts.append("## Run Overview")
    parts.append(f"Run ID : {run['run_id']}")
    parts.append(f"Video  : {run['video_name']}")
    parts.append(f"Status : {run['status']}")
    parts.append(
        f"Config : preset={cfg.get('brush_preset','?')} | "
        f"depth_model={cfg.get('depth_model','?')} | "
        f"colmap_profile={cfg.get('colmap_profile','?')} | "
        f"max_frames={cfg.get('max_frames','?')}"
    )

    # ── Layer 2 ───────────────────────────────────────────────────────────────
    l2 = ctx["layer2"]
    parts.append("\n## Layer 2 Frame Filtering")
    if l2.get("available"):
        parts.append(
            f"Kept: {l2['n_kept']} | Rejected: {l2['n_rejected']} | "
            f"Total extracted: {l2['n_total']}"
        )
        parts.append(
            f"Rejection breakdown: blur={l2['n_blur']} | duplicate={l2['n_dup']} | "
            f"exposure={l2['n_exposure']} | static/redundant={l2['n_static']}"
        )
    else:
        parts.append("Not available (layer2 was skipped or metadata missing).")

    # ── Layer 3 ───────────────────────────────────────────────────────────────
    l3 = ctx["layer3"]
    parts.append("\n## Layer 3 Pre-Capture Audit")
    if not l3.get("available"):
        parts.append("Not available (layer3 was skipped or audit JSON missing).")
    else:
        parts.append(
            f"Readiness     : {l3['readiness']}  (quality_score={l3['quality_score']:.2f}/1.00)"
        )
        parts.append(
            f"Issues        : {l3['n_critical']} critical | "
            f"{l3['n_warnings']} warnings | {l3['n_info']} info"
        )
        parts.append(f"Frames        : {l3['n_frames']} kept | "
                     f"{l3['n_rejected_blur']} rejected-blur | "
                     f"{l3['n_rejected_dup']} rejected-dup | "
                     f"{l3['n_rejected_exp']} rejected-exposure | "
                     f"{l3['n_rejected_stat']} rejected-static")

        # Motion
        mot = l3.get("motion", {})
        cov = l3.get("coverage", {})
        parts.append(f"\nMotion analysis:")
        parts.append(
            f"  rotation_fraction          = {mot.get('median_rotation_fraction', 'n/a')}"
            f"  (good <0.50, critical >0.80)"
        )
        parts.append(
            f"  median_translation_px      = {mot.get('median_translation_px', 'n/a')}"
        )
        parts.append(
            f"  static_pair_fraction       = {mot.get('static_pair_fraction', 'n/a')}"
        )
        parts.append(
            f"  n_directions_covered       = {mot.get('n_directions_covered', 'n/a')}/8"
        )
        parts.append(
            f"  mean_resultant_length      = {mot.get('mean_resultant_length', 'n/a')}"
            f"  (1.0=linear; <0.40=good orbit)"
        )

        # Coverage
        parts.append(f"\nCoverage analysis:")
        parts.append(
            f"  trajectory_type            = {cov.get('trajectory_type', 'n/a')}"
        )
        parts.append(
            f"  orbit_score                = {cov.get('orbit_score', 'n/a')}"
            f"  (good >0.70)"
        )
        parts.append(
            f"  coverage_completeness      = {cov.get('coverage_completeness', 'n/a')}"
            f"  (fraction of 8 sectors covered)"
        )
        parts.append(
            f"  loop_closed                = {cov.get('loop_closed', 'n/a')}"
        )
        if cov.get("uncovered_sectors"):
            parts.append(
                f"  uncovered_sectors          = {cov['uncovered_sectors']}"
            )
        parts.append(
            f"  frame_overlap_score        = {cov.get('frame_overlap_score', 'n/a')}"
            f"  (good >0.50)"
        )
        parts.append(
            f"  parallax_score             = {cov.get('parallax_score', 'n/a')}"
            f"  (good >0.40)"
        )

        # Lighting
        lit   = l3.get("lighting", {})
        bri   = lit.get("brightness", {})
        jumps = lit.get("exposure_jumps", {})
        ctemp = lit.get("color_temperature", {})
        parts.append(f"\nLighting analysis:")
        parts.append(
            f"  brightness_cv              = {bri.get('cv', 'n/a')}"
            f"  (good <0.10, critical >0.25)"
        )
        parts.append(
            f"  mean_brightness_L          = {bri.get('mean_L', 'n/a')}/100"
        )
        parts.append(
            f"  n_exposure_jumps           = {jumps.get('count', 'n/a')}"
            f"  (good <3, critical >10)"
        )
        parts.append(
            f"  white_balance_RG_drift     = {ctemp.get('drift_score', 'n/a')}"
            f"  (good <0.05, warning >0.06)"
        )
        parts.append(
            f"  lighting_stability_score   = {lit.get('lighting_stability_score', 'n/a')}"
            f"  (0=unstable, 1=stable)"
        )
        parts.append(
            f"  n_dark_frames              = {lit.get('n_dark_frames', 'n/a')}"
        )
        parts.append(
            f"  n_overexposed_frames       = {lit.get('n_overexposed_frames', 'n/a')}"
        )

        # Texture
        tex    = l3.get("texture", {})
        kp_den = tex.get("keypoint_density", {})
        parts.append(f"\nTexture analysis:")
        parts.append(
            f"  mean_keypoints_per_frame   = {kp_den.get('mean', 'n/a')}"
            f"  (good >40)"
        )
        parts.append(
            f"  low_texture_fraction       = {tex.get('low_texture_fraction', 'n/a')}"
            f"  (good <0.15)"
        )

        # Issues
        if l3["issues"]:
            parts.append(f"\nLayer 3 Issues detected ({len(l3['issues'])} total):")
            for iss in l3["issues"]:
                sev   = iss.get("severity", "?").upper()
                conf  = iss.get("confidence", 0)
                nl    = iss.get("nlp_data", {})
                parts.append(
                    f"\n  [{sev}] {iss['code']}  "
                    f"confidence={conf:.0%}  "
                    f"colmap_impact={iss.get('colmap_impact','?')}  "
                    f"splat_impact={iss.get('splat_impact','?')}"
                )
                parts.append(
                    f"    key_metric : {nl.get('key_metric','?')} = {nl.get('key_value','?')}"
                )
                parts.append(f"    detail     : {iss.get('detail','')}")
        else:
            parts.append("\nLayer 3 Issues: None detected.")

    # ── Layer 6 ───────────────────────────────────────────────────────────────
    l6 = ctx["layer6"]
    parts.append("\n## Layer 6 Post-Splat Quality Analysis")
    if not l6.get("available"):
        parts.append(
            "Not available (training may not have completed or layer6 was skipped)."
        )
    else:
        n_crit = sum(1 for i in l6["issues"] if i.get("severity") == "CRITICAL")
        n_warn = sum(1 for i in l6["issues"] if i.get("severity") == "WARNING")
        parts.append(
            f"Quality Grade : {l6['quality_grade']}  "
            f"({n_crit} critical, {n_warn} warnings)"
        )

        # PLY
        ply = l6.get("ply", {})
        if ply.get("ok"):
            parts.append(f"\nPLY (Gaussian field):")
            parts.append(
                f"  total_gaussians      = {ply.get('total_gaussians', 0):,}"
            )
            fs = ply.get("floater_stats", {})
            if fs:
                parts.append(
                    f"  floater_fraction     = {fs.get('fraction', 0):.3f}"
                    f"  ({fs.get('count', 0):,} Gaussians; good <0.05)"
                )
            ss = ply.get("scale_stats", {})
            if ss:
                rel = ss.get("relative_to_scene", {})
                parts.append(
                    f"  fraction_oversized   = {ss.get('fraction_oversized', 0):.3f}"
                    f"  (good <0.10)"
                )
                parts.append(
                    f"  p95_scale_fraction   = {rel.get('p95_max_scale_frac', 0):.4f}"
                )
            op = ply.get("opacity_stats", {})
            if op:
                parts.append(
                    f"  opacity_mean         = {op.get('mean', 0):.3f}"
                    f"  fraction_below_0.1  = {op.get('fraction_below_01', 0):.3f}"
                    f"  (good <0.30)"
                )
            dm = ply.get("density_map", {})
            if dm:
                parts.append(
                    f"  empty_voxel_fraction = {dm.get('empty_voxel_fraction', 0):.3f}"
                    f"  (good <0.60)"
                )

        # Coverage
        cov6 = l6.get("coverage", {})
        if cov6.get("ok"):
            vs = cov6.get("visibility_stats", {})
            parts.append(f"\nCamera Coverage:")
            if vs:
                parts.append(
                    f"  mean_visibility      = {vs.get('mean_visibility', 0):.1f}"
                    f" cameras/Gaussian  (good >4)"
                )
                parts.append(
                    f"  unseen_fraction      = {vs.get('unseen_fraction', 0):.3f}"
                    f"  (good <0.05)"
                )
                parts.append(
                    f"  weak_fraction        = {vs.get('weak_fraction', 0):.3f}"
                    f"  (seen by ≤2 cameras; good <0.20)"
                )
            wz = cov6.get("weak_zone") or {}
            if isinstance(wz, dict):
                cent = wz.get("centroid")
                if cent and len(cent) == 3:
                    parts.append(
                        f"  weak_zone_centroid   = [{cent[0]:.2f}, {cent[1]:.2f}, "
                        f"{cent[2]:.2f}]  (3D centre of worst-covered region)"
                    )

        # Render
        rnd = l6.get("render", {})
        if rnd.get("ok"):
            gs = rnd.get("global_stats", {})
            if gs:
                psnr = gs.get("psnr", {})
                ssim = gs.get("ssim", {})
                l1   = gs.get("l1_error", {})
                w5   = gs.get("worst_5_views", [])
                parts.append(
                    f"\nRender Quality ({rnd.get('n_views_analyzed', 0)} views analyzed):"
                )
                parts.append(
                    f"  PSNR mean            = {psnr.get('mean', 0):.2f} dB"
                    f"  min = {psnr.get('min', 0):.2f} dB  (good ≥30 dB)"
                )
                parts.append(
                    f"  SSIM mean            = {ssim.get('mean', 0):.4f}"
                    f"  (good ≥0.85)"
                )
                parts.append(
                    f"  L1_error mean        = {l1.get('mean', 0):.5f}"
                )
                if w5:
                    parts.append(
                        f"  worst_5_views        = {', '.join(w5)}"
                    )
        elif not rnd.get("available", True):
            parts.append("\nRender Quality: no eval renders found (Brush eval may be disabled).")

        # Depth
        dpt = l6.get("depth", {})
        if dpt.get("ok"):
            parts.append(
                f"\nDepth Analysis:"
            )
            parts.append(
                f"  mismatch_fraction    = {dpt.get('global_mismatch_fraction', 0):.3f}"
                f"  (good <0.15)"
            )
            wc = dpt.get("worst_cameras", [])
            if wc:
                parts.append(
                    f"  worst_cameras        = "
                    f"{[c.get('image_name','?') for c in wc[:3]]}"
                )

        # Issues
        if l6["issues"]:
            parts.append(
                f"\nLayer 6 Issues detected ({len(l6['issues'])} total):"
            )
            for iss in l6["issues"]:
                sev  = iss.get("severity", "?")
                conf = iss.get("confidence", 0)
                nl   = iss.get("nlp_data", {})
                sh   = nl.get("spatial_hint") or iss.get("spatial_hint")
                parts.append(
                    f"\n  [{sev}] {iss['code']}  confidence={conf:.0%}"
                )
                parts.append(
                    f"    metric   : {iss.get('metric','?')} = {iss.get('value','?')}"
                    f"  (threshold {iss.get('threshold','?')})"
                )
                parts.append(f"    detail   : {iss.get('detail','')}")
                if sh and isinstance(sh, (list, tuple)) and len(sh) == 3:
                    parts.append(
                        f"    spatial_hint : [{sh[0]:.2f}, {sh[1]:.2f}, {sh[2]:.2f}]"
                    )
                worst = nl.get("worst_views") or nl.get("worst_stems")
                if worst:
                    parts.append(f"    worst_views  : {worst[:5]}")
        else:
            parts.append("\nLayer 6 Issues: None detected.")

    parts.append(
        "\n---\nProduce your Layer 7 analysis report now, using the exact "
        "section structure specified in your instructions."
    )

    return "\n".join(parts)


def build_messages(ctx: dict) -> list[dict]:
    """Return the [system, user] message list for the Groq API call."""
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user",   "content": build_user_message(ctx)},
    ]
