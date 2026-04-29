"""CapturePolicy dataclass + lenient validator.

Mirrors the Swift `CapturePolicy` struct in
ios_app/Splattr/CapturePolicy/CapturePolicy.swift. The Swift side encodes
this exact JSON shape into `manifest.json` under the `capture_policy`
key. AR-Layer 4 (pose bridge) will pick reconstruction defaults from it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


SUPPORTED_PATH_PATTERNS: tuple[str, ...] = (
    "orbit",
    "spiral",
    "perimeter_then_center",
    "corridor_forward_back",
    "facade_sweep",
    "wide_arc",
    "rotation_only_object",
)


def is_valid_path_pattern(pattern: str) -> bool:
    return pattern in SUPPORTED_PATH_PATTERNS


@dataclass
class FrameBudget:
    min: int
    target: int
    max: int

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "FrameBudget":
        return cls(
            min=int(d.get("min", 60)),
            target=int(d.get("target", 180)),
            max=int(d.get("max", 300)),
        )


@dataclass
class CoverageTargets:
    min_directions_8: int
    min_orbit_score: float
    loop_closure_required: bool

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "CoverageTargets":
        return cls(
            min_directions_8=int(d.get("min_directions_8", 6)),
            min_orbit_score=float(d.get("min_orbit_score", 0.5)),
            loop_closure_required=bool(d.get("loop_closure_required", True)),
        )


@dataclass
class DistanceBand:
    near: float
    far: float

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "DistanceBand":
        return cls(
            near=float(d.get("near", 1.0)),
            far=float(d.get("far", 6.0)),
        )


@dataclass
class Movement:
    max_speed_mps: float
    expect_translation: bool
    expect_rotation_only: bool

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Movement":
        return cls(
            max_speed_mps=float(d.get("max_speed_mps", 0.4)),
            expect_translation=bool(d.get("expect_translation", True)),
            expect_rotation_only=bool(d.get("expect_rotation_only", False)),
        )


@dataclass
class CapturePolicy:
    scene_type: str
    scan_mode: str
    path_pattern: str
    frame_budget: FrameBudget
    coverage_targets: CoverageTargets
    distance_band_meters: DistanceBand
    movement: Movement
    ar_features_required: list[str] = field(default_factory=list)
    ar_features_preferred: list[str] = field(default_factory=list)
    tutorial_run: bool = False
    tutorial_skipped: bool = False
    policy_version: int = 1

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "CapturePolicy":
        return cls(
            scene_type=str(d.get("scene_type", "room")),
            scan_mode=str(d.get("scan_mode", "room_perimeter_sweep")),
            path_pattern=str(d.get("path_pattern", "perimeter_then_center")),
            frame_budget=FrameBudget.from_dict(d.get("frame_budget", {}) or {}),
            coverage_targets=CoverageTargets.from_dict(d.get("coverage_targets", {}) or {}),
            distance_band_meters=DistanceBand.from_dict(d.get("distance_band_meters", {}) or {}),
            movement=Movement.from_dict(d.get("movement", {}) or {}),
            ar_features_required=list(d.get("ar_features_required", []) or []),
            ar_features_preferred=list(d.get("ar_features_preferred", []) or []),
            tutorial_run=bool(d.get("tutorial_run", False)),
            tutorial_skipped=bool(d.get("tutorial_skipped", False)),
            policy_version=int(d.get("policy_version", 1)),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "scene_type": self.scene_type,
            "scan_mode": self.scan_mode,
            "path_pattern": self.path_pattern,
            "frame_budget": {"min": self.frame_budget.min,
                             "target": self.frame_budget.target,
                             "max": self.frame_budget.max},
            "coverage_targets": {
                "min_directions_8": self.coverage_targets.min_directions_8,
                "min_orbit_score": self.coverage_targets.min_orbit_score,
                "loop_closure_required": self.coverage_targets.loop_closure_required,
            },
            "distance_band_meters": {"near": self.distance_band_meters.near,
                                     "far": self.distance_band_meters.far},
            "movement": {
                "max_speed_mps": self.movement.max_speed_mps,
                "expect_translation": self.movement.expect_translation,
                "expect_rotation_only": self.movement.expect_rotation_only,
            },
            "ar_features_required": list(self.ar_features_required),
            "ar_features_preferred": list(self.ar_features_preferred),
            "tutorial_run": self.tutorial_run,
            "tutorial_skipped": self.tutorial_skipped,
            "policy_version": self.policy_version,
        }


def parse_capture_policy(raw: Any) -> tuple[CapturePolicy | None, list[str]]:
    """Lenient parse. Returns (policy, warnings).

    Layer 0 server passes the whole manifest['capture_policy'] (which may be
    missing entirely) here. Missing → returns (None, []) — that's not an error
    in Layer 0, just "no policy attached" (e.g. fake_phone uploads).
    Malformed → returns (None, [reasons]) and the server logs the warnings.
    """
    if raw is None:
        return None, []
    if not isinstance(raw, dict):
        return None, [f"capture_policy is not an object (got {type(raw).__name__})"]
    warnings: list[str] = []
    try:
        policy = CapturePolicy.from_dict(raw)
    except (TypeError, ValueError) as e:
        return None, [f"capture_policy parse failed: {e!r}"]
    if not is_valid_path_pattern(policy.path_pattern):
        warnings.append(
            f"capture_policy.path_pattern={policy.path_pattern!r} is not a recognised pattern; "
            f"AR-Layer 4 may fall back to defaults."
        )
    if policy.frame_budget.min > policy.frame_budget.target > policy.frame_budget.max:
        warnings.append("capture_policy.frame_budget min/target/max ordering is wrong")
    if policy.distance_band_meters.near >= policy.distance_band_meters.far:
        warnings.append("capture_policy.distance_band_meters.near >= far")
    if policy.policy_version != 1:
        warnings.append(
            f"capture_policy.policy_version={policy.policy_version} not v1 — laptop will use defaults"
        )
    return policy, warnings
