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
