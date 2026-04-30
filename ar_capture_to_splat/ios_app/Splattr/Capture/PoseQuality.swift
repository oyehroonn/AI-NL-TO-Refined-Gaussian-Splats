//
//  PoseQuality.swift
//  Maps ARKit's tracking state + raw feature density into a single
//  pose_quality_score in [0, 1] that the manifest carries per frame.
//

import ARKit
import Foundation

enum PoseQuality {

    /// `featurePointsCount` is from `frame.rawFeaturePoints?.points.count` (≥0).
    /// Returns a score where 1.0 = pristine tracking + dense features and
    /// 0.0 = tracking unavailable or zero features.
    static func score(trackingState: ARCamera.TrackingState,
                      featurePointsCount: Int) -> Double {
        let trackingFactor: Double
        switch trackingState {
        case .normal:
            trackingFactor = 1.0
        case .limited(let reason):
            switch reason {
            case .initializing:           trackingFactor = 0.55
            case .relocalizing:           trackingFactor = 0.40
            case .excessiveMotion:        trackingFactor = 0.45
            case .insufficientFeatures:   trackingFactor = 0.35
            @unknown default:             trackingFactor = 0.45
            }
        case .notAvailable:
            trackingFactor = 0.0
        }
        // Feature-density factor: rises quickly, plateaus around 1500.
        let density = min(Double(featurePointsCount) / 1500.0, 1.0)
        // Weighted average: tracking dominates because pose is meaningless
        // when tracking is limited, regardless of feature count.
        return 0.7 * trackingFactor + 0.3 * density
    }

    /// String label expected by manifest.frames[].tracking_state.
    static func trackingStateLabel(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal:        return "normal"
        case .limited:       return "limited"
        case .notAvailable:  return "notAvailable"
        }
    }

    /// Manifest's tracking_reason field (only populated when limited).
    static func trackingReasonLabel(_ s: ARCamera.TrackingState) -> String? {
        if case .limited(let r) = s {
            switch r {
            case .initializing:         return "initializing"
            case .relocalizing:         return "relocalizing"
            case .excessiveMotion:      return "excessiveMotion"
            case .insufficientFeatures: return "insufficientFeatures"
            @unknown default:           return "unknown"
            }
        }
        return nil
    }

    /// Manifest's world_mapping_status field.
    static func worldMappingStatusLabel(_ s: ARFrame.WorldMappingStatus) -> String {
        switch s {
        case .notAvailable:  return "notAvailable"
        case .limited:       return "limited"
        case .extending:     return "extending"
        case .mapped:        return "mapped"
        @unknown default:    return "unknown"
        }
    }
}
