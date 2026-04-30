//
//  CapturePolicy.swift
//  AR-Layer 1 — the data artifact every capture session produces.
//
//  Encoded into manifest.json under the top-level "capture_policy" key
//  (CAPTURE_PROTOCOL.md §6). The Python sibling lives at
//  ar_capture_to_splat/scripts/capture_policy_layer/policy_schema.py and
//  must stay shape-compatible.
//

import Foundation

/// Stable string IDs (kept untyped so the policy survives Swift renames).
enum PathPattern {
    static let orbit                  = "orbit"
    static let spiral                 = "spiral"
    static let perimeterThenCenter    = "perimeter_then_center"
    static let corridorForwardBack    = "corridor_forward_back"
    static let facadeSweep            = "facade_sweep"
    static let wideArc                = "wide_arc"
    static let rotationOnlyObject     = "rotation_only_object"

    static let all: [String] = [
        orbit, spiral, perimeterThenCenter, corridorForwardBack,
        facadeSweep, wideArc, rotationOnlyObject
    ]
}

struct FrameBudget: Codable, Equatable, Hashable {
    var min: Int
    var target: Int
    var max: Int
}

struct CoverageTargets: Codable, Equatable, Hashable {
    var min_directions_8: Int
    var min_orbit_score: Double
    var loop_closure_required: Bool
}

struct DistanceBand: Codable, Equatable, Hashable {
    var near: Double
    var far: Double
}

struct MovementConstraints: Codable, Equatable, Hashable {
    var max_speed_mps: Double
    var expect_translation: Bool
    var expect_rotation_only: Bool
}

/// The artifact produced by AR-Layer 1. Read by AR-Layer 2 (live HUD),
/// AR-Layer 4 (pose bridge / reconstruction defaults), and Layer 7 (AI
/// retake advice phrasing).
struct CapturePolicy: Codable, Equatable, Hashable {
    var scene_type: String              // "room", "object", …
    var scan_mode: String               // "room_perimeter_sweep", …
    var path_pattern: String            // PathPattern.*
    var frame_budget: FrameBudget
    var coverage_targets: CoverageTargets
    var distance_band_meters: DistanceBand
    var movement: MovementConstraints
    var ar_features_required: [String]
    var ar_features_preferred: [String]
    var tutorial_run: Bool
    var tutorial_skipped: Bool
    var policy_version: Int

    static let currentVersion = 1
}

extension CapturePolicy {
    /// Builds a policy from a CaptureMode + tutorial state. This is the
    /// only place CapturePolicy values are constructed at runtime.
    static func make(from mode: CaptureMode,
                     tutorialRun: Bool,
                     tutorialSkipped: Bool) -> CapturePolicy {
        CapturePolicy(
            scene_type: mode.sceneType.rawValue,
            scan_mode: mode.scanModeID,
            path_pattern: mode.pathPattern,
            frame_budget: mode.frameBudget,
            coverage_targets: mode.coverageTargets,
            distance_band_meters: mode.distanceBand,
            movement: mode.movement,
            ar_features_required: mode.arFeaturesRequired,
            ar_features_preferred: mode.arFeaturesPreferred,
            tutorial_run: tutorialRun,
            tutorial_skipped: tutorialSkipped,
            policy_version: CapturePolicy.currentVersion
        )
    }
}
