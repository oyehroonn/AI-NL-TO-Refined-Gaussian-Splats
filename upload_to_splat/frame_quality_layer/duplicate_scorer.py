#!/usr/bin/env python3
"""
Near-duplicate detection via difference hashing (dHash).

dHash: resize to (hash_size+1, hash_size), compute horizontal gradient bits.
Hamming distance between two hashes → similarity.

  distance 0   → identical
  distance ≤ 8 → near-duplicate (tunable threshold)
  distance > 8 → different enough to keep

We run a greedy forward scan: keep a frame if its dHash is far enough from
ALL previously kept frames. This is O(n²) but n is at most a few hundred frames,
so it is fast in practice.

Returns a set of filenames to KEEP (non-duplicates).
"""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np


def _dhash(img_gray: np.ndarray, hash_size: int = 8) -> np.ndarray:
    """Return dHash as a boolean array of length hash_size*hash_size."""
    resized = cv2.resize(img_gray, (hash_size + 1, hash_size), interpolation=cv2.INTER_AREA)
    diff = resized[:, 1:] > resized[:, :-1]  # horizontal gradient
    return diff.flatten()


def _hamming(a: np.ndarray, b: np.ndarray) -> int:
    return int(np.count_nonzero(a != b))


def compute_hashes(image_paths: list[Path], hash_size: int = 8) -> dict[str, np.ndarray]:
    """Return {filename: dhash_array} for all paths."""
    hashes: dict[str, np.ndarray] = {}
    for path in image_paths:
        img = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        if img is None:
            hashes[path.name] = np.zeros(hash_size * hash_size, dtype=bool)
        else:
            hashes[path.name] = _dhash(img, hash_size)
    return hashes


def select_non_duplicates(
    image_paths: list[Path],
    *,
    hamming_threshold: int = 8,
    hash_size: int = 8,
) -> tuple[set[str], dict[str, float]]:
    """
    Greedy forward scan: keep frame if dHash distance to all kept frames > threshold.

    Returns:
      (keep_set, redundancy_scores)
      redundancy_score: 0.0 = unique, 1.0 = identical to a kept frame
    """
    hashes = compute_hashes(image_paths, hash_size)
    max_dist = hash_size * hash_size  # maximum possible Hamming distance

    kept_hashes: list[np.ndarray] = []
    keep_set: set[str] = set()
    redundancy_scores: dict[str, float] = {}

    for path in image_paths:
        name = path.name
        h = hashes[name]
        if not kept_hashes:
            keep_set.add(name)
            kept_hashes.append(h)
            redundancy_scores[name] = 0.0
        else:
            min_dist = min(_hamming(h, kh) for kh in kept_hashes)
            redundancy = max(0.0, 1.0 - min_dist / max_dist)
            redundancy_scores[name] = redundancy
            if min_dist > hamming_threshold:
                keep_set.add(name)
                kept_hashes.append(h)

    return keep_set, redundancy_scores
