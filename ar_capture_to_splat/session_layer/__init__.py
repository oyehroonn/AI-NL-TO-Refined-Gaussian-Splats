"""AR-Layer 0 — session orchestration, QR handoff, capture-package intake.

Public entry point: `run_layer0()` (see run_layer0.py).
Protocol contract: CAPTURE_PROTOCOL.md (sibling file).
"""

from .session import CaptureSession, allocate_run_dir, detect_lan_ip, find_free_port
from .scene_types import SCENE_TYPES, scene_tip_set
from .run_layer0 import run_layer0

__all__ = [
    "CaptureSession",
    "allocate_run_dir",
    "detect_lan_ip",
    "find_free_port",
    "SCENE_TYPES",
    "scene_tip_set",
    "run_layer0",
]
