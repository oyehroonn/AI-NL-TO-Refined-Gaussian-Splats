//
//  CaptureModeCatalog.swift
//  Maps each SceneType to its CaptureMode. Source of truth for the 8
//  modes shipped in AR-Layer 1 (the schema in CAPTURE_PROTOCOL.md §6).
//

import Foundation

enum CaptureModeCatalog {

    /// All modes, keyed by SceneType.
    static let byScene: [SceneType: CaptureMode] = [
        .room:                    .room,
        .object:                  .object,
        .small_object_turntable:  .turntable,
        .corridor:                .corridor,
        .storefront:              .storefront,
        .outdoor_facade:          .facade,
        .vehicle:                 .vehicle,
        .large_indoor:            .largeIndoor,
    ]

    static func mode(for scene: SceneType) -> CaptureMode {
        byScene[scene] ?? .room
    }
}

extension CaptureMode {

    static let room = CaptureMode(
        sceneType: .room,
        scanModeID: "room_perimeter_sweep",
        pathPattern: PathPattern.perimeterThenCenter,
        frameBudget: FrameBudget(min: 60, target: 200, max: 320),
        coverageTargets: CoverageTargets(min_directions_8: 6,
                                         min_orbit_score: 0.55,
                                         loop_closure_required: true),
        distanceBand: DistanceBand(near: 1.0, far: 6.0),
        movement: MovementConstraints(max_speed_mps: 0.4,
                                      expect_translation: true,
                                      expect_rotation_only: false),
        arFeaturesRequired: ["worldTracking"],
        arFeaturesPreferred: ["sceneDepth", "smoothedSceneDepth", "sceneReconstruction"],
        displayHeadline: "Perimeter sweep, then corners",
        displaySummary: "200 frames · 1–6 m · loop required",
        badgeSymbol: "house.fill"
    )

    static let object = CaptureMode(
        sceneType: .object,
        scanModeID: "object_orbit_spiral",
        pathPattern: PathPattern.orbit,
        frameBudget: FrameBudget(min: 80, target: 180, max: 280),
        coverageTargets: CoverageTargets(min_directions_8: 8,
                                         min_orbit_score: 0.85,
                                         loop_closure_required: true),
        distanceBand: DistanceBand(near: 0.4, far: 1.5),
        movement: MovementConstraints(max_speed_mps: 0.3,
                                      expect_translation: true,
                                      expect_rotation_only: false),
        arFeaturesRequired: ["worldTracking"],
        arFeaturesPreferred: ["sceneDepth"],
        displayHeadline: "Two orbits — knee, then chest",
        displaySummary: "180 frames · 0.4–1.5 m · full circle ×2",
        badgeSymbol: "cube.fill"
    )

    static let turntable = CaptureMode(
        sceneType: .small_object_turntable,
        scanModeID: "turntable_in_hand",
        pathPattern: PathPattern.rotationOnlyObject,
        frameBudget: FrameBudget(min: 60, target: 120, max: 220),
        coverageTargets: CoverageTargets(min_directions_8: 6,
                                         min_orbit_score: 0.7,
                                         loop_closure_required: false),
        distanceBand: DistanceBand(near: 0.2, far: 0.6),
        movement: MovementConstraints(max_speed_mps: 0.15,
                                      expect_translation: false,
                                      expect_rotation_only: true),
        arFeaturesRequired: ["worldTracking"],
        arFeaturesPreferred: [],
        displayHeadline: "Phone steady — rotate the object",
        displaySummary: "120 frames · 0.2–0.6 m · rotation only",
        badgeSymbol: "circle.hexagonpath.fill"
    )

    static let corridor = CaptureMode(
        sceneType: .corridor,
        scanModeID: "corridor_forward_back",
        pathPattern: PathPattern.corridorForwardBack,
        frameBudget: FrameBudget(min: 60, target: 140, max: 240),
        coverageTargets: CoverageTargets(min_directions_8: 4,
                                         min_orbit_score: 0.25,
                                         loop_closure_required: false),
        distanceBand: DistanceBand(near: 0.8, far: 8.0),
        movement: MovementConstraints(max_speed_mps: 0.5,
                                      expect_translation: true,
                                      expect_rotation_only: false),
        arFeaturesRequired: ["worldTracking"],
        arFeaturesPreferred: ["sceneDepth"],
        displayHeadline: "Walk through, then walk back",
        displaySummary: "140 frames · 0.8–8 m · two passes",
        badgeSymbol: "rectangle.portrait.fill"
    )

    static let storefront = CaptureMode(
        sceneType: .storefront,
        scanModeID: "storefront_door_to_back",
        pathPattern: PathPattern.corridorForwardBack,
        frameBudget: FrameBudget(min: 80, target: 180, max: 280),
        coverageTargets: CoverageTargets(min_directions_8: 5,
                                         min_orbit_score: 0.3,
                                         loop_closure_required: false),
        distanceBand: DistanceBand(near: 1.0, far: 6.0),
        movement: MovementConstraints(max_speed_mps: 0.4,
                                      expect_translation: true,
                                      expect_rotation_only: false),
        arFeaturesRequired: ["worldTracking"],
        arFeaturesPreferred: ["sceneDepth"],
        displayHeadline: "Doorway in, sweep left and right",
        displaySummary: "180 frames · 1–6 m · avoid window glare",
        badgeSymbol: "storefront.fill"
    )

    static let facade = CaptureMode(
        sceneType: .outdoor_facade,
        scanModeID: "facade_lateral_sweep",
        pathPattern: PathPattern.facadeSweep,
        frameBudget: FrameBudget(min: 80, target: 200, max: 320),
        coverageTargets: CoverageTargets(min_directions_8: 3,
                                         min_orbit_score: 0.15,
                                         loop_closure_required: false),
        distanceBand: DistanceBand(near: 5.0, far: 20.0),
        movement: MovementConstraints(max_speed_mps: 0.6,
                                      expect_translation: true,
                                      expect_rotation_only: false),
        arFeaturesRequired: ["worldTracking"],
        arFeaturesPreferred: [],
        displayHeadline: "Walk parallel, then move closer",
        displaySummary: "200 frames · 5–20 m · sun behind you",
        badgeSymbol: "building.2.fill"
    )

    static let vehicle = CaptureMode(
        sceneType: .vehicle,
        scanModeID: "vehicle_walkaround",
        pathPattern: PathPattern.orbit,
        frameBudget: FrameBudget(min: 100, target: 200, max: 320),
        coverageTargets: CoverageTargets(min_directions_8: 8,
                                         min_orbit_score: 0.85,
                                         loop_closure_required: true),
        distanceBand: DistanceBand(near: 1.0, far: 3.0),
        movement: MovementConstraints(max_speed_mps: 0.4,
                                      expect_translation: true,
                                      expect_rotation_only: false),
        arFeaturesRequired: ["worldTracking"],
        arFeaturesPreferred: ["sceneDepth"],
        displayHeadline: "Walk around twice — low, then high",
        displaySummary: "200 frames · 1–3 m · two heights",
        badgeSymbol: "car.fill"
    )

    static let largeIndoor = CaptureMode(
        sceneType: .large_indoor,
        scanModeID: "large_arc_sweep",
        pathPattern: PathPattern.wideArc,
        frameBudget: FrameBudget(min: 100, target: 240, max: 360),
        coverageTargets: CoverageTargets(min_directions_8: 6,
                                         min_orbit_score: 0.45,
                                         loop_closure_required: false),
        distanceBand: DistanceBand(near: 1.5, far: 12.0),
        movement: MovementConstraints(max_speed_mps: 0.5,
                                      expect_translation: true,
                                      expect_rotation_only: false),
        arFeaturesRequired: ["worldTracking"],
        arFeaturesPreferred: ["sceneDepth", "sceneReconstruction"],
        displayHeadline: "Wide arcs — pause briefly along the way",
        displaySummary: "240 frames · 1.5–12 m · multi-stop arc",
        badgeSymbol: "building.columns.fill"
    )
}
