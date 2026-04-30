//
//  GuidanceEngine.swift
//  Picks the status-chip copy shown in the live HUD. Pure function of the
//  current ARKit + coverage state — no per-instance memory; just runs each
//  HUD tick.
//

import ARKit
import Foundation

enum GuidanceLevel {
    case normal       // green — keep going
    case warn         // amber — adjust something
    case critical     // red — tracking failure / pause
}

struct GuidanceState: Equatable {
    let label: String
    let level: GuidanceLevel
}

enum GuidanceEngine {

    static func evaluate(
        trackingState: ARCamera.TrackingState,
        worldMappingStatus: ARFrame.WorldMappingStatus,
        coverage: CoverageGrid,
        framesAccepted: Int,
        framesTarget: Int,
        recentSpeedMetersPerSecond: Double,
        policy: CapturePolicy
    ) -> GuidanceState {

        // Tracking failures dominate.
        if case .limited(let reason) = trackingState {
            switch reason {
            case .initializing:
                return .init(label: "warming up — hold still", level: .warn)
            case .relocalizing:
                return .init(label: "lost tracking — hold still", level: .critical)
            case .excessiveMotion:
                return .init(label: "move slower", level: .warn)
            case .insufficientFeatures:
                return .init(label: "need texture — point at detail", level: .warn)
            @unknown default:
                return .init(label: "tracking limited", level: .warn)
            }
        }
        if case .notAvailable = trackingState {
            return .init(label: "tracking unavailable", level: .critical)
        }

        // Speed warnings.
        if recentSpeedMetersPerSecond > policy.movement.max_speed_mps * 1.5 {
            return .init(label: "move slower", level: .warn)
        }

        // Coverage hints.
        if framesAccepted >= max(20, framesTarget / 4) {
            // Only nag about coverage after we've had a chance to gather some.
            let yawCovered = coverage.coveredYawSectors
            if yawCovered < CoverageGrid.yawSectorCount - 1 {
                return .init(label: "cover the rest of the room", level: .warn)
            }
            if coverage.coverageFraction < 0.55 {
                return .init(label: "tilt up and down", level: .warn)
            }
        }

        if framesAccepted >= framesTarget {
            return .init(label: "ready to upload", level: .normal)
        }

        return .init(label: "tracking · keep moving slowly", level: .normal)
    }
}
