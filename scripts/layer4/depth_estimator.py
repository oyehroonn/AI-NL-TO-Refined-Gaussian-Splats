#!/usr/bin/env python3
"""
Monocular depth estimation — Layer 4.

Generates a dpt/ folder next to images/ containing one uint8 grayscale
PNG per frame.  Brush reads dpt/ at training time and uses the maps to:
  1. Initialize Gaussians at dense depth locations (vs sparse COLMAP pts only)
  2. Apply per-frame depth supervision loss during training
  3. Constrain near/far scene bounds

Output format confirmed against test_dataset:
  - uint8 PNG (0=far, 255=near — MiDaS inverse-depth convention)
  - Resolution: ~384 on short axis, proportional width rounded to ×32
    e.g. 960×540 input  → 384×672 depth
         1920×1080 input → 384×672 depth  (same — model normalises to 384)
  - One file per image, same stem name

Supported models (in quality order):
  "DPT_Large"   — MiDaS DPT-L  (~400 MB).  Matches test_dataset exactly. DEFAULT.
  "DPT_Hybrid"  — MiDaS DPT-H  (~200 MB).  Slightly lower quality, faster.
  "MiDaS_small" — MiDaS v2.1   (~80 MB).   Fast, lower quality. Good for CPU.
  "depth_anything_v2_small" — DA-v2-S (HuggingFace). Newest SOTA, fast.

Device priority: MPS (Apple Silicon) → CUDA → CPU.
"""

from __future__ import annotations

import time
from pathlib import Path

import cv2
import numpy as np

IMAGE_EXTS = frozenset({".jpg", ".jpeg", ".png", ".bmp"})

# ── Device detection ──────────────────────────────────────────────────────────

def _best_device():
    import torch
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


# ── Model loaders ─────────────────────────────────────────────────────────────

def _load_midas(model_type: str, device):
    """Load MiDaS model via torch.hub. Downloads weights on first call (~200-400 MB)."""
    import torch
    print(f"[Layer 4] Loading MiDaS {model_type} on {device}…")
    print("          (first run downloads model weights, cached after that)")
    model = torch.hub.load("intel-isl/MiDaS", model_type, pretrained=True, trust_repo=True)
    model.to(device).eval()

    midas_transforms = torch.hub.load("intel-isl/MiDaS", "transforms", trust_repo=True)
    if model_type in ("DPT_Large", "DPT_Hybrid"):
        transform = midas_transforms.dpt_transform
    else:
        transform = midas_transforms.small_transform

    return model, transform


def _load_depth_anything_v2(device):
    """Load Depth Anything V2 Small via HuggingFace transformers."""
    from transformers import AutoImageProcessor, AutoModelForDepthEstimation
    import torch

    print("[Layer 4] Loading Depth Anything V2 Small via HuggingFace transformers…")
    model_id = "depth-anything/Depth-Anything-V2-Small-hf"
    processor = AutoImageProcessor.from_pretrained(model_id)
    model = AutoModelForDepthEstimation.from_pretrained(model_id)
    model.to(device).eval()
    return model, processor


# ── Inference helpers ─────────────────────────────────────────────────────────

def _infer_midas(model, transform, img_rgb: np.ndarray, device) -> np.ndarray:
    """
    Run MiDaS on an HWC uint8 RGB image.
    Returns float32 disparity map at the model's output resolution.
    """
    import torch
    import torch.nn.functional as F

    input_batch = transform(img_rgb).to(device)  # 1CHW

    with torch.no_grad():
        prediction = model(input_batch)           # 1HW or HW
        if prediction.dim() == 3:
            prediction = prediction.squeeze(0)   # HW

    return prediction.cpu().float().numpy()


def _infer_depth_anything(model, processor, img_rgb: np.ndarray, device) -> np.ndarray:
    """
    Run Depth Anything V2 on an HWC uint8 RGB image.
    Returns float32 depth map.
    """
    import torch
    from PIL import Image as PILImage

    pil_img = PILImage.fromarray(img_rgb)
    inputs = processor(images=pil_img, return_tensors="pt")
    inputs = {k: v.to(device) for k, v in inputs.items()}

    with torch.no_grad():
        outputs = model(**inputs)
        depth = outputs.predicted_depth.squeeze().cpu().float().numpy()

    return depth


def _normalise_to_uint8(depth_float: np.ndarray) -> np.ndarray:
    """
    Normalise float disparity/depth map to uint8 [0, 255].
    Convention: 255 = closest (high disparity = near).
    This matches MiDaS output convention and test_dataset format.
    """
    d_min = depth_float.min()
    d_max = depth_float.max()
    if (d_max - d_min) < 1e-6:
        return np.zeros_like(depth_float, dtype=np.uint8)
    normalised = (depth_float - d_min) / (d_max - d_min) * 255.0
    return normalised.astype(np.uint8)


# ── Main batch function ───────────────────────────────────────────────────────

def generate_depth_maps(
    images_dir: Path,
    output_dir: Path,
    *,
    model_type: str = "DPT_Large",
    device=None,
    verbose: bool = True,
    skip_existing: bool = True,
) -> dict:
    """
    Generate depth maps for all images in images_dir.
    Writes uint8 PNG to output_dir/<stem>.png.

    Returns stats dict.
    """
    images_dir  = images_dir.resolve()
    output_dir  = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    frames = sorted(
        [p for p in images_dir.iterdir() if p.suffix.lower() in IMAGE_EXTS],
        key=lambda p: p.name,
    )
    if not frames:
        return {"error": "no images found", "n_processed": 0}

    # Device
    if device is None:
        device = _best_device()

    if verbose:
        print(f"[Layer 4] Generating {len(frames)} depth maps with {model_type} on {device}")

    # Load model
    try:
        if model_type == "depth_anything_v2_small":
            model, proc_or_transform = _load_depth_anything_v2(device)
            infer_fn = lambda img: _infer_depth_anything(model, proc_or_transform, img, device)
        else:
            model, proc_or_transform = _load_midas(model_type, device)
            infer_fn = lambda img: _infer_midas(model, proc_or_transform, img, device)
    except Exception as e:
        return {"error": f"model load failed: {e}", "n_processed": 0}

    # Process frames
    t_start = time.perf_counter()
    n_processed = 0
    n_skipped = 0
    depths_shape = None

    for i, path in enumerate(frames):
        out_path = output_dir / (path.stem + ".png")

        if skip_existing and out_path.exists():
            n_skipped += 1
            continue

        img_bgr = cv2.imread(str(path))
        if img_bgr is None:
            if verbose:
                print(f"[Layer 4]   skip (unreadable): {path.name}")
            continue

        img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)

        try:
            depth_float = infer_fn(img_rgb)
        except Exception as e:
            if verbose:
                print(f"[Layer 4]   error on {path.name}: {e}")
            continue

        depth_uint8 = _normalise_to_uint8(depth_float)
        depths_shape = depth_uint8.shape
        cv2.imwrite(str(out_path), depth_uint8)
        n_processed += 1

        if verbose and (i % 10 == 0 or i == len(frames) - 1):
            elapsed = time.perf_counter() - t_start
            fps = n_processed / max(elapsed, 1e-3)
            remaining = (len(frames) - i - 1) / max(fps, 1e-3)
            print(
                f"[Layer 4]   {i+1}/{len(frames)}  "
                f"{fps:.1f} frames/s  "
                f"ETA {remaining:.0f}s  "
                f"out={depth_uint8.shape[1]}×{depth_uint8.shape[0]}"
            )

    elapsed = time.perf_counter() - t_start
    fps = n_processed / max(elapsed, 1e-3)

    if verbose:
        print(
            f"[Layer 4] Done: {n_processed} depth maps written "
            f"({n_skipped} skipped, existing).  "
            f"{elapsed:.1f}s total  ({fps:.1f} frames/s)"
        )

    return {
        "model": model_type,
        "device": str(device),
        "n_frames": len(frames),
        "n_processed": n_processed,
        "n_skipped": n_skipped,
        "output_dir": str(output_dir),
        "depth_shape_hw": list(depths_shape) if depths_shape is not None else None,
        "elapsed_seconds": round(elapsed, 2),
        "fps": round(fps, 2),
    }
