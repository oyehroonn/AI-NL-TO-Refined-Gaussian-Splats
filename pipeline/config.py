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

    def validate(self) -> None:
        if self.matcher_type not in ("sequential_matcher", "exhaustive_matcher"):
            raise ValueError(f"Invalid matcher_type: {self.matcher_type}")
        if self.model_type not in ("3dgs", "nerfstudio"):
            raise ValueError(f"Invalid model_type: {self.model_type}")
        if self.interval < 1:
            raise ValueError("interval must be >= 1")
        if self.brush_total_steps < 1:
            raise ValueError("brush_total_steps must be >= 1")
