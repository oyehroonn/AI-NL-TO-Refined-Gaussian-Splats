//
//  CaptureMode.swift
//  AR-Layer 1 — one CaptureMode per scene type. The catalog (CaptureModeCatalog)
//  maps each SceneType to its mode. ModeCopy supplies the per-mode tutorial
//  step list so the catalog stays focused on *capture-time* parameters.
//

import Foundation

struct CaptureMode: Equatable, Hashable, Identifiable {
    let id: String                  // == scanModeID (e.g. "room_perimeter_sweep")
    let sceneType: SceneType
    let scanModeID: String
    let pathPattern: String         // one of PathPattern.*
    let frameBudget: FrameBudget
    let coverageTargets: CoverageTargets
    let distanceBand: DistanceBand
    let movement: MovementConstraints
    let arFeaturesRequired: [String]
    let arFeaturesPreferred: [String]

    /// Headline shown on the ModeConfirm screen.
    let displayHeadline: String
    /// One-line technical summary shown on ModeConfirm + the Capture HUD chip.
    let displaySummary: String
    /// SF Symbol used as the mode badge.
    let badgeSymbol: String

    init(
        sceneType: SceneType,
        scanModeID: String,
        pathPattern: String,
        frameBudget: FrameBudget,
        coverageTargets: CoverageTargets,
        distanceBand: DistanceBand,
        movement: MovementConstraints,
        arFeaturesRequired: [String],
        arFeaturesPreferred: [String],
        displayHeadline: String,
        displaySummary: String,
        badgeSymbol: String
    ) {
        self.id = scanModeID
        self.sceneType = sceneType
        self.scanModeID = scanModeID
        self.pathPattern = pathPattern
        self.frameBudget = frameBudget
        self.coverageTargets = coverageTargets
        self.distanceBand = distanceBand
        self.movement = movement
        self.arFeaturesRequired = arFeaturesRequired
        self.arFeaturesPreferred = arFeaturesPreferred
        self.displayHeadline = displayHeadline
        self.displaySummary = displaySummary
        self.badgeSymbol = badgeSymbol
    }
}
