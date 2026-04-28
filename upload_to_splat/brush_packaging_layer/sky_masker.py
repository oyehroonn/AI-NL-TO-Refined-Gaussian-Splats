"""
Sky mask generator — produces masks/ folder for Brush.

Brush reads masks/<stem>.png alongside images/<stem>.jpg.
The mask's red channel (or alpha if RGBA) is used as a per-pixel opacity
weight during training loss computation:
    loss = pixel_error * mask_value
So: white (255) = include, black (0) = ignore.

Sky pixels get black mask → no gradient → no Gaussians form there → no floaters.

Detection heuristic (no ML, cv2+numpy only)
────────────────────────────────────────────
1. Only examine the top `sky_top_fraction` of the image (default 55%).
   Sky is almost always at the top; this avoids false-positives on blue walls.

2. Convert to HSV.  Sky candidates:
     Blue sky   : H ∈ [170°,270°], S ∈ [0.10,0.72], V > 0.25
     Overcast   : S < 0.18, V > 0.68             (white/grey cloud)
     Hazy       : H ∈ [20°,200°], S < 0.35, V > 0.75  (haze/glare)

3. Morphological close + open to remove salt-and-pepper noise.

4. Guard: if the detected sky region covers < 5% of the top area,
   the scene is probably indoors or the sky is not visible — skip the mask
   (write a full-white mask = no masking).

5. Any sky region below the detected sky ceiling is also masked
   (flood-fill downwards from largest sky blob).

Output: masks/<stem>.png  — grayscale uint8, same resolution as source image.
"""
from __future__ import annotations

import time
from pathlib import Path

import cv2
import numpy as np

IMAGE_EXTS = frozenset({".jpg", ".jpeg", ".png", ".bmp"})

_SKY_MIN_FRACTION  = 0.05    # ignore result if sky covers < this fraction of the top region
_MORPH_KERNEL_SIZE = 19      # morphological cleanup kernel (pixels)


def _detect_sky_mask(img_bgr: np.ndarray, sky_top_fraction: float) -> np.ndarray:
    """
    Returns a uint8 mask (same H×W as img_bgr): 255=keep, 0=sky.
    """
    h, w = img_bgr.shape[:2]
    top_h = max(1, int(h * sky_top_fraction))

    mask = np.full((h, w), 255, dtype=np.uint8)   # start all-white (keep)

    img_hsv = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2HSV).astype(np.float32)
    H = img_hsv[:top_h, :, 0] * 2.0    # OpenCV H is 0–180 → scale to 0–360
    S = img_hsv[:top_h, :, 1] / 255.0  # 0–1
    V = img_hsv[:top_h, :, 2] / 255.0  # 0–1

    # Blue/cyan sky
    blue = (H >= 170) & (H <= 270) & (S >= 0.10) & (S <= 0.72) & (V > 0.25)
    # Overcast / white cloud
    white = (S < 0.18) & (V > 0.68)
    # Hazy glare
    hazy = (H >= 20) & (H <= 200) & (S < 0.35) & (V > 0.75)

    sky_top = (blue | white | hazy).astype(np.uint8)

    # Morphological cleanup
    k = cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE, (_MORPH_KERNEL_SIZE, _MORPH_KERNEL_SIZE)
    )
    sky_top = cv2.morphologyEx(sky_top, cv2.MORPH_CLOSE, k)
    sky_top = cv2.morphologyEx(sky_top, cv2.MORPH_OPEN, k)

    sky_fraction = sky_top.mean()
    if sky_fraction < _SKY_MIN_FRACTION:
        return mask   # no sky detected → all-white (no masking)

    # Flood-fill downward from the sky ceiling:
    # find the lowest row in each column where sky ends, then mask above it
    # Simple approach: mask all sky pixels + extend downward only within
    # connected regions touching the top edge.
    # Use connected-component analysis to keep only blobs touching top row.
    n_labels, labels, stats, _ = cv2.connectedComponentsWithStats(sky_top)
    sky_final = np.zeros((top_h, w), dtype=np.uint8)
    for label in range(1, n_labels):
        y_top_blob = stats[label, cv2.CC_STAT_TOP]
        if y_top_blob == 0:   # blob touches top edge → keep as sky
            sky_final[labels == label] = 1

    # If nothing touches top edge, fall back to raw detection
    if sky_final.sum() == 0:
        sky_final = sky_top

    mask[:top_h, :][sky_final.astype(bool)] = 0
    return mask


def generate_sky_masks(
    images_dir: Path,
    masks_dir: Path,
    *,
    sky_top_fraction: float = 0.55,
    verbose: bool = True,
    skip_existing: bool = True,
) -> dict:
    """
    Generate sky masks for all images in images_dir.
    Writes masks/<stem>.png to masks_dir (same resolution as source image).

    Returns stats dict.
    """
    images_dir = images_dir.resolve()
    masks_dir  = masks_dir.resolve()
    masks_dir.mkdir(parents=True, exist_ok=True)

    frames = sorted(
        [p for p in images_dir.iterdir() if p.suffix.lower() in IMAGE_EXTS],
        key=lambda p: p.name,
    )
    if not frames:
        return {"error": "no images found", "n_processed": 0, "n_sky_detected": 0}

    t0 = time.perf_counter()
    n_sky   = 0
    n_skip  = 0
    n_proc  = 0

    for path in frames:
        out_path = masks_dir / (path.stem + ".png")
        if skip_existing and out_path.exists():
            n_skip += 1
            continue

        img_bgr = cv2.imread(str(path))
        if img_bgr is None:
            continue

        mask = _detect_sky_mask(img_bgr, sky_top_fraction)
        sky_pixels = (mask == 0).sum()
        if sky_pixels > 0:
            n_sky += 1

        cv2.imwrite(str(out_path), mask)
        n_proc += 1

    elapsed = time.perf_counter() - t0

    if verbose:
        print(
            f"[Layer 5 sky masks] {n_proc} masks written "
            f"({n_sky} with sky detected, {n_skip} skipped).  "
            f"{elapsed:.1f}s → {masks_dir}"
        )

    return {
        "n_processed": n_proc,
        "n_sky_detected": n_sky,
        "n_skipped": n_skip,
        "output_dir": str(masks_dir),
        "elapsed_seconds": round(elapsed, 2),
    }
