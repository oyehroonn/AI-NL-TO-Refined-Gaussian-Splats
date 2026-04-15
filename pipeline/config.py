"""
Defaults for the baseline pipeline (Layer 0).

Paths are resolved relative to the repository root unless absolute.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def default_brush_app_binary(root: Path | None = None) -> Path | None:
    """Release binary from a local `brush/` tree, if present."""
    root = root or repo_root()
    for name in ("brush_app", "brush_app.exe"):
        p = root / "brush" / "target" / "release" / name
        if p.is_file():
            return p
    return None


@dataclass
class PipelineConfig:
    """Single-run settings; construct per run from CLI or tests."""

    runs_root: Path = field(default_factory=lambda: repo_root() / "runs")
    max_frames: int = 250
    keep_all_frames: bool = False
    resize_width: int | None = None
    resize_height: int | None = None
    target_fps: float | None = None
    # When True, also copies the video to the run root; input/input.mp4 is always created.
    copy_video_into_run: bool = False
    matcher_type: str = "sequential_matcher"
    interval: int = 1
    model_type: str = "3dgs"
    # Override brush_app; None = look for brush/target/release/brush_app under repo_root().
    brush_binary: Path | None = None
    # After COLMAP, run Brush when True and a binary exists (use --skip-brush to disable).
    run_brush: bool = True
    # When False (default), pass --with-viewer so the Brush window opens. True = terminal-only train.
    brush_headless: bool = False
    # Passed to brush_app --total-steps; export fires at this interval once (= one final PLY).
    brush_total_steps: int = 8000

    # ── Layer 2: frame quality scoring and keyframe selection ──────────────
    run_layer2: bool = True
    # Laplacian variance floor; frames below are blurry and rejected
    blur_threshold: float = 80.0
    # Exposure score floor [0,1]; frames below are over/under-exposed
    exposure_threshold: float = 0.15
    # dHash Hamming distance; frames closer than this to a kept frame are dropped
    hamming_threshold: int = 8
    # Motion score floor; frames below are near-static (redundant viewpoint)
    motion_floor: float = 0.03
    # Safety: relax thresholds if too few frames would survive
    min_keep_frames: int = 30

    # ── Layer 3: pre-COLMAP dataset audit ─────────────────────────────────
    run_layer3: bool = True
    # Halt the pipeline if any critical issues are detected
    layer3_halt_on_critical: bool = False

    # ── Layer 4: monocular depth maps (dpt/) ──────────────────────────────
    run_layer4: bool = True
    # Depth model: DPT_Large (default, matches test_dataset), DPT_Hybrid, MiDaS_small, depth_anything_v2_small
    depth_model: str = "DPT_Large"

    # ── COLMAP matcher auto-selection ──────────────────────────────────────
    # When True, auto-switch to exhaustive_matcher if frame count <= exhaustive_threshold
    auto_select_matcher: bool = True
    # Frame count at or below which exhaustive matching is used (all-pairs C(n,2))
    exhaustive_threshold: int = 150
    # Sequential overlap window (used when sequential_matcher is selected)
    sequential_overlap: int = 20

    # ── COLMAP extraction/matching profile ─────────────────────────────────
    # One of: normal | video_low_texture | video_blurry | wide_lens_phone | auto
    # 'auto' reads layer3_audit.json and picks the best profile automatically.
    colmap_profile: str = "auto"

    # ── Layer 5: Brush packaging + training wrapper ─────────────────────────
    # Dense init.ply: back-project DPT depth maps into COLMAP world space
    run_dense_init: bool = True
    # DPT back-projection samples per frame (total ≈ n_frames × this)
    dense_init_samples: int = 2000
    # Sky mask generation: produce masks/ folder to suppress sky floaters
    run_sky_masks: bool = True
    # Brush quality preset: "draft" | "standard" | "quality" | "custom" | "auto"
    # "auto" = show interactive menu before training
    brush_preset: str = "auto"
    # Default preset when brush_preset="auto" and pipeline is non-interactive
    brush_default_preset: str = "standard"

    # ── Layer 6: post-splat quality analysis ───────────────────────────────
    run_layer6: bool = True
    # Save per-view error heatmap PNGs to layer6_heatmaps/
    layer6_save_heatmaps: bool = True
    # Save coverage/depth .npy arrays (large; off by default)
    layer6_save_numpy_grids: bool = False

    def validate(self) -> None:
        if self.matcher_type not in ("sequential_matcher", "exhaustive_matcher"):
            raise ValueError(f"Invalid matcher_type: {self.matcher_type}")
        if self.model_type not in ("3dgs", "nerfstudio"):
            raise ValueError(f"Invalid model_type: {self.model_type}")
        if self.interval < 1:
            raise ValueError("interval must be >= 1")
        if self.max_frames < 1:
            raise ValueError("max_frames must be >= 1")
        if self.resize_width is not None and self.resize_width < 1:
            raise ValueError("resize_width must be >= 1")
        if self.resize_height is not None and self.resize_height < 1:
            raise ValueError("resize_height must be >= 1")
        if self.target_fps is not None and self.target_fps <= 0:
            raise ValueError("target_fps must be > 0")
        if self.brush_total_steps < 1:
            raise ValueError("brush_total_steps must be >= 1")
