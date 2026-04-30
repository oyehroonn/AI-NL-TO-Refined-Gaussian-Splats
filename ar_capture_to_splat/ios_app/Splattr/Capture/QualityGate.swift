//
//  QualityGate.swift
//  Decides accepted_for_training per frame. Combines tracking_state,
//  blur_score, min-distance from the previously accepted frame, and
//  whether the frame contributes to coverage.
//

import ARKit
import Foundation
import simd

struct QualityGate {

    // Mode-derived thresholds (set in init from CapturePolicy).
    let blurThreshold: Double
    let minDistanceMeters: Double
    let cooldownSeconds: TimeInterval

    /// Build a gate for a given policy.
    init(policy: CapturePolicy) {
        // Indoor scenes are typically low-light with motion blur sneaking in
        // around 80–150. Outdoor scenes can be much sharper. We bias the
        // threshold by mode: tighter for facade/outdoor, looser for room.
        switch policy.scan_mode {
        case CaptureMode.facade.scanModeID,
             CaptureMode.vehicle.scanModeID:
            self.blurThreshold = 120.0
        case CaptureMode.turntable.scanModeID:
            self.blurThreshold = 60.0
        default:
            self.blurThreshold = 90.0
        }
        // Min spacing scales with the policy distance band — see plan §3.
        self.minDistanceMeters = (policy.distance_band_meters.near
                                + policy.distance_band_meters.far) / 30.0
        // Don't accept frames more often than this.
        self.cooldownSeconds = 0.05
    }

    enum Decision: Equatable {
        case accept(reason: String)
        case reject(reason: String)
    }

    /// Evaluate a candidate frame.
    /// - Parameters:
    ///   - trackingState: from frame.camera.trackingState
    ///   - blur: from BlurDetector.score(...)
    ///   - cameraTransform: frame.camera.transform
    ///   - lastAcceptedTransform: pose of the most-recently accepted frame, nil if first
    ///   - lastAcceptedTimestamp: time of the most-recently accepted frame
    ///   - now: timestamp of this candidate
    func decide(
        trackingState: ARCamera.TrackingState,
        blur: Double,
        cameraTransform: simd_float4x4,
        lastAcceptedTransform: simd_float4x4?,
        lastAcceptedTimestamp: TimeInterval?,
        now: TimeInterval,
        wouldFreshenCoverage: Bool
    ) -> Decision {
        // Tracking gate.
        guard case .normal = trackingState else {
            return .reject(reason: "tracking_not_normal")
        }

        // Blur gate.
        if blur < blurThreshold {
            return .reject(reason: "blur_below_threshold")
        }

        // Cooldown.
        if let lastT = lastAcceptedTimestamp, now - lastT < cooldownSeconds {
            return .reject(reason: "cooldown")
        }

        // Min-distance OR fresh-coverage gate. We'll accept if either
        // condition is met — if the user moved, OR if they pointed at
        // something new without moving (e.g., tilting the phone).
        if let lastTr = lastAcceptedTransform {
            let dx = cameraTransform.translation.x - lastTr.translation.x
            let dy = cameraTransform.translation.y - lastTr.translation.y
            let dz = cameraTransform.translation.z - lastTr.translation.z
            let distance = sqrt(dx * dx + dy * dy + dz * dz)
            let movedEnough = Double(distance) >= minDistanceMeters
            if !(movedEnough || wouldFreshenCoverage) {
                return .reject(reason: "no_motion_no_new_coverage")
            }
        }

        return .accept(reason: "ok")
    }
}
