"""AR-Layer 4 — pose bridge.

Converts an `ar_runs/<id>/capture/` directory (produced by Layer 3) into
a COLMAP-shaped run dir under `runs/<new_id>/` so the existing splat
pipeline (`upload_to_splat/` Layers 5/6/7) trains on it unchanged.

Public entry: `run_layer4(ar_run_dir, ...)` — see `run_layer4.py`.
"""
from .run_layer4 import run_layer4  # noqa: F401
