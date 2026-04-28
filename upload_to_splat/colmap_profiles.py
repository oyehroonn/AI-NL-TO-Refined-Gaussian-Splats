"""
COLMAP feature-extraction and matching profiles.

Each profile bundles camera model + SIFT + matcher settings for a specific
capture scenario.  Applied in run_glomap.py when building commands.

Profile choice guide
────────────────────
normal             Well-lit, textured video from a standard lens (≥ 24 mm equiv).
                   Fastest. Use this unless you have a specific problem.

video_low_texture  Smooth walls, corridors, ground planes — minimal surface detail.
                   Enables DSP-SIFT (domain-size pooling) + affine shape estimation
                   + guided matching.  Forces CPU extraction (much slower) but finds
                   2–4× more inlier matches on low-texture surfaces.

video_blurry       Motion-blur or slight defocus throughout the clip (handheld pan).
                   Very low SIFT peak threshold extracts keypoints from soft regions.
                   DSP-SIFT + guided matching for precision.  Affine shape OFF —
                   unstable when keypoint localisation is imprecise.

wide_lens_phone    Ultra-wide phone camera (≤ 18 mm equiv / dedicated ultra-wide).
                   OPENCV model (k1, k2, p1, p2) + corrected focal-length prior.
                   Guided matching corrects for distortion not yet fitted at match
                   time.

auto               Read Layer 3 audit JSON and pick normal / video_low_texture /
                   video_blurry automatically based on detected issues.
                   (Resolved at pipeline run time; not a real profile name.)

COLMAP flag reference
─────────────────────
--SiftExtraction.domain_size_pooling 1   DSP-SIFT: scale-pooled descriptors
--SiftExtraction.estimate_affine_shape 1 ASIFT (forces CPU, much slower)
--FeatureExtraction.use_gpu 0            Force CPU extraction
--SiftExtraction.max_num_features N      Keypoints per image (default 8192)
--SiftExtraction.peak_threshold T        Lower = more keypoints from soft areas
--FeatureMatching.guided_matching 1      F/H-guided re-verification of matches
--ImageReader.camera_model MODEL         Camera distortion model
--ImageReader.default_focal_length_factor F  Prior: focal = F * max(W, H)
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ColmapProfile:
    name: str
    description: str

    # ── Camera model ──────────────────────────────────────────────────────
    camera_model: str
    # Prior for focal length as fraction of max(W, H).
    # None = COLMAP default (1.2).  Wide lenses need ~0.7–0.9.
    focal_length_factor: float | None

    # ── SIFT feature extraction ───────────────────────────────────────────
    max_num_features: int
    peak_threshold: float        # COLMAP default: 0.0066667
    domain_size_pooling: bool    # DSP-SIFT
    estimate_affine_shape: bool  # ASIFT — forces CPU
    # Explicitly pass --FeatureExtraction.use_gpu 0 when True.
    # Set automatically when estimate_affine_shape=True (COLMAP requires it).
    force_cpu_extraction: bool

    # ── Matching ──────────────────────────────────────────────────────────
    guided_matching: bool

    # ── Sequential-matcher overlap boost ─────────────────────────────────
    # Added on top of the pipeline's configured sequential_overlap value.
    # e.g. base=20, boost=10 → 30 neighbours checked per frame.
    overlap_boost: int


_PROFILES: dict[str, ColmapProfile] = {
    "normal": ColmapProfile(
        name="normal",
        description=(
            "Standard SIFT + SIMPLE_PINHOLE. "
            "Best for well-lit, textured, stable footage from a standard lens."
        ),
        camera_model="SIMPLE_PINHOLE",
        focal_length_factor=None,
        max_num_features=8192,
        peak_threshold=0.0066667,
        domain_size_pooling=False,
        estimate_affine_shape=False,
        force_cpu_extraction=False,
        guided_matching=False,
        overlap_boost=0,
    ),
    "video_low_texture": ColmapProfile(
        name="video_low_texture",
        description=(
            "DSP-SIFT + affine shape + guided matching. "
            "For smooth walls, corridors, ground planes with little surface detail. "
            "CPU-only extraction — slow, but finds 2–4× more inlier matches."
        ),
        camera_model="SIMPLE_PINHOLE",
        focal_length_factor=None,
        max_num_features=16384,
        peak_threshold=0.004,
        domain_size_pooling=True,
        estimate_affine_shape=True,
        force_cpu_extraction=True,   # COLMAP requires CPU when estimate_affine_shape=1
        guided_matching=True,
        overlap_boost=10,
    ),
    "video_blurry": ColmapProfile(
        name="video_blurry",
        description=(
            "Very low SIFT peak threshold + DSP-SIFT + guided matching. "
            "For motion-blurred or slightly out-of-focus footage. "
            "Affine shape disabled — unreliable when keypoint localisation is imprecise."
        ),
        camera_model="SIMPLE_PINHOLE",
        focal_length_factor=None,
        max_num_features=16384,
        peak_threshold=0.003,
        domain_size_pooling=True,
        estimate_affine_shape=False,
        force_cpu_extraction=False,
        guided_matching=True,
        overlap_boost=10,
    ),
    "wide_lens_phone": ColmapProfile(
        name="wide_lens_phone",
        description=(
            "OPENCV camera model (k1,k2,p1,p2 distortion) + corrected focal-length prior. "
            "For ultra-wide phone cameras (≤ 18 mm equiv / dedicated ultra-wide lens). "
            "Guided matching corrects for distortion not yet fitted at match time."
        ),
        camera_model="OPENCV",
        focal_length_factor=0.85,   # ultra-wide actual focal ≈ 0.85 × max(W,H); COLMAP default 1.2
        max_num_features=8192,
        peak_threshold=0.0066667,
        domain_size_pooling=False,
        estimate_affine_shape=False,
        force_cpu_extraction=False,
        guided_matching=True,
        overlap_boost=0,
    ),
}

PROFILE_NAMES = list(_PROFILES.keys())
AUTO_SENTINEL = "auto"


def get_profile(name: str) -> ColmapProfile:
    """Return a ColmapProfile by name.  Does NOT resolve 'auto' — call resolve_profile() for that."""
    if name not in _PROFILES:
        raise ValueError(
            f"Unknown COLMAP profile '{name}'. "
            f"Valid profiles: {PROFILE_NAMES + [AUTO_SENTINEL]}"
        )
    return _PROFILES[name]


def resolve_profile(name: str, layer3_audit_path: Path | None = None) -> ColmapProfile:
    """
    Resolve a profile name, including the 'auto' sentinel.

    Auto-selection logic (reads layer3_audit.json if available):
      LOW_TEXTURE_FRAMES issue detected  →  video_low_texture
      DARK_FRAMES or blur-related issues →  video_blurry  (lower priority than texture)
      Otherwise                          →  normal
    """
    if name != AUTO_SENTINEL:
        return get_profile(name)

    # Auto mode: try to read Layer 3 audit
    if layer3_audit_path is None or not layer3_audit_path.exists():
        print("[COLMAP profile] auto: no layer3_audit.json found → using 'normal'")
        return _PROFILES["normal"]

    try:
        audit = json.loads(layer3_audit_path.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"[COLMAP profile] auto: could not read layer3_audit.json ({e}) → using 'normal'")
        return _PROFILES["normal"]

    issues = audit.get("issues", [])
    issue_codes = {iss.get("code", "") for iss in issues}
    severities = {iss.get("code", ""): iss.get("severity", "") for iss in issues}

    # Low texture: strongest signal → use dedicated profile
    if "LOW_TEXTURE_FRAMES" in issue_codes:
        sev = severities.get("LOW_TEXTURE_FRAMES", "warning")
        print(
            f"[COLMAP profile] auto: LOW_TEXTURE_FRAMES ({sev}) detected "
            f"→ profile='video_low_texture'"
        )
        return _PROFILES["video_low_texture"]

    # Blurry: LOW_PARALLAX or many dark/blurry frames
    blur_codes = {"LOW_PARALLAX", "DARK_FRAMES"}
    if blur_codes & issue_codes:
        triggered = blur_codes & issue_codes
        print(
            f"[COLMAP profile] auto: {triggered} detected "
            f"→ profile='video_blurry'"
        )
        return _PROFILES["video_blurry"]

    print("[COLMAP profile] auto: no texture/blur issues detected → profile='normal'")
    return _PROFILES["normal"]


def profile_summary(profile: ColmapProfile) -> str:
    """One-line log string describing the active profile."""
    extras = []
    if profile.domain_size_pooling:
        extras.append("DSP-SIFT")
    if profile.estimate_affine_shape:
        extras.append("affine-shape(CPU)")
    if profile.guided_matching:
        extras.append("guided-match")
    extra_str = " + ".join(extras) if extras else "standard-SIFT"
    focal = f"focal_factor={profile.focal_length_factor}" if profile.focal_length_factor else ""
    parts = [
        f"profile={profile.name}",
        f"camera={profile.camera_model}",
        focal,
        f"features={profile.max_num_features}",
        f"peak={profile.peak_threshold:.6f}",
        extra_str,
    ]
    return "  ".join(p for p in parts if p)


def build_feature_extractor_cmd(
    image_path: str,
    database_path: str,
    profile: ColmapProfile,
) -> str:
    """Build the colmap feature_extractor command for the given profile."""
    parts = [
        "colmap feature_extractor",
        f"--image_path {image_path}",
        f"--database_path {database_path}",
        "--ImageReader.single_camera 1",
        f"--ImageReader.camera_model {profile.camera_model}",
        f"--SiftExtraction.max_num_features {profile.max_num_features}",
        f"--SiftExtraction.peak_threshold {profile.peak_threshold:.7f}",
    ]
    if profile.focal_length_factor is not None:
        parts.append(f"--ImageReader.default_focal_length_factor {profile.focal_length_factor}")
    if profile.domain_size_pooling:
        parts.append("--SiftExtraction.domain_size_pooling 1")
    if profile.estimate_affine_shape:
        parts.append("--SiftExtraction.estimate_affine_shape 1")
    if profile.force_cpu_extraction:
        parts.append("--FeatureExtraction.use_gpu 0")
    return " ".join(parts)


def build_matcher_cmd(
    database_path: str,
    actual_matcher: str,
    matcher_flags: str,
    profile: ColmapProfile,
) -> str:
    """Build the colmap matcher command for the given profile."""
    cmd = f"colmap {actual_matcher} --database_path {database_path}{matcher_flags}"
    if profile.guided_matching:
        cmd += " --FeatureMatching.guided_matching 1"
    return cmd
