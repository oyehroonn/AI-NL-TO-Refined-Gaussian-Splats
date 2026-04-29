"""AR-Layer 1 — capture policy layer.

The iOS Splattr app embeds a `capture_policy` object inside manifest.json
that describes HOW the user was guided to capture (path pattern, distance
band, frame budget, coverage targets, AR feature requirements). This
package owns the Python-side schema, validation, and (later) the
mode-aware reconstruction defaults for AR-Layer 4 (pose bridge) and
beyond.

Layer 0 (session) accepts manifests with or without `capture_policy`,
because the existing `fake_phone` test harness needs to keep working.
"""

from .policy_schema import (
    CapturePolicy,
    FrameBudget,
    CoverageTargets,
    DistanceBand,
    Movement,
    parse_capture_policy,
    is_valid_path_pattern,
    SUPPORTED_PATH_PATTERNS,
)

__all__ = [
    "CapturePolicy",
    "FrameBudget",
    "CoverageTargets",
    "DistanceBand",
    "Movement",
    "parse_capture_policy",
    "is_valid_path_pattern",
    "SUPPORTED_PATH_PATTERNS",
]
