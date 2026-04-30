//
//  Manifest.swift
//  Matches the manifest.json contract in CAPTURE_PROTOCOL.md §3 exactly.
//  This is the *authoritative* description of one capture; the laptop
//  validates against the same shape.
//

import Foundation

struct Manifest: Codable {
    let schema_version: Int
    let session_id: String
    let run_id: String
    let video_name: String
    let scene_type: String
    let started_at_unix: Double
    let ended_at_unix: Double
    let device: Device
    let summary: Summary
    let capture_policy: CapturePolicy?    // AR-Layer 1; optional on the wire
    let frames: [Frame]

    struct Device: Codable {
        let model: String
        let os: String
        let lidar_supported: Bool
        let scene_reconstruction_supported: Bool
        let ar_world_tracking_configuration: ARConfig
    }

    struct ARConfig: Codable {
        let video_format: VideoFormat
        let frame_semantics: [String]
        let plane_detection: [String]
        let scene_reconstruction: String

        struct VideoFormat: Codable {
            let width: Int
            let height: Int
            let fps: Int
        }
    }

    struct Summary: Codable {
        let frames_captured: Int
        let frames_kept: Int
        let duration_seconds: Double
        let tracking_state_breakdown: [String: Int]
        let world_mapping_status_breakdown: [String: Int]
        let coverage_summary: CoverageSummary
        let preview_run: Bool
        let enhance_run: Bool

        struct CoverageSummary: Codable {
            let covered_fraction: Double
            let weak_regions: [WeakRegion]
            struct WeakRegion: Codable { let label: String; let score: Double }
        }
    }

    struct Frame: Codable {
        let frame_id: Int
        let timestamp: Double
        let image_path: String
        let camera_transform_world: [[Double]]
        let camera_intrinsics: [[Double]]
        let image_width: Int
        let image_height: Int
        let tracking_state: String
        let tracking_reason: String?
        let world_mapping_status: String?
        let raw_feature_points_count: Int?
        let has_scene_depth: Bool
        let scene_depth_path: String?
        let smoothed_scene_depth_path: String?
        let pose_quality_score: Double?
        let blur_score: Double?
        let coverage_score: Double?
        let accepted_for_training: Bool
    }
}

/// In-memory representation of a frame the iOS app captured. Pose data
/// is stub for AR-Layer-0 (no ARKit yet); slot stays so AR-Layer-2 can
/// fill it in without changing call sites.
struct CapturedFrame: Equatable, Hashable {
    let id: Int
    let timestamp: Date
    let jpegData: Data
    let width: Int
    let height: Int
}

/// What the laptop returns from POST /upload.
struct UploadSummary: Equatable, Hashable {
    let runID: String
    let framesReceived: Int
    let depthReceived: Int
    let trackingBreakdown: [String: Int]
}
