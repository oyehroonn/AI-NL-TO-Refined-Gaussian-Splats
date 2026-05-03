//
//  Manifest.swift
//  Matches the manifest.json contract in CAPTURE_PROTOCOL.md §3 + §6.
//  AR-Layer 2 populates every per-frame field with a real value (no stubs).
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
    /// Path to the ARWorldMap sidecar inside the upload (`world_map.arworldmap`).
    /// Nil when worldMap export failed or device didn't reach mapped state.
    let world_map_path: String?
    /// Path to the sceneReconstruction mesh inside the upload (`scene_mesh.obj`).
    /// Nil on devices without LiDAR / without mesh anchors.
    let mesh_path: String?
    /// Path to the rejected-frames log (`rejected_frames.json`). Always present
    /// when at least one frame was rejected during the session.
    let rejected_frames_path: String?

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
        /// Path to the JPEG inside the upload. Nil only for rejected-frame
        /// records (carried for negative-training signal).
        let image_path: String?
        let camera_transform_world: [[Double]]
        let camera_intrinsics: [[Double]]
        let image_width: Int
        let image_height: Int
        let tracking_state: String
        let tracking_reason: String?
        let world_mapping_status: String?
        let light_estimate: LightEstimate?
        let raw_feature_points_count: Int?
        let has_scene_depth: Bool
        let scene_depth_path: String?
        let smoothed_scene_depth_path: String?
        /// Per-pixel uint8 confidence side-car for `scene_depth_path`
        /// (Apple values 0/1/2 per ARDepthData docs; 2 = high confidence).
        let depth_confidence_path: String?
        /// Per-frame raw feature points dump
        /// (`feature_points/frame_<id>.bin`, see CAPTURE_PROTOCOL.md §3).
        let feature_points_path: String?
        let pose_quality_score: Double?
        let blur_score: Double?
        let coverage_score: Double?
        /// True if the JPEG was captured via `captureHighResolutionFrame`
        /// (sharper still). False when only the preview-resolution stream
        /// was available.
        let captured_high_resolution: Bool?
        /// Apple radiometric values for inter-frame color normalization.
        let exposure: Exposure?
        /// EXIF dict (ISO, shutter, white-balance gains) when available.
        let exif: ExifData?
        let accepted_for_training: Bool
        /// Reason a frame was excluded (only set when accepted_for_training=false).
        let reject_reason: String?

        struct LightEstimate: Codable {
            let ambient_intensity: Double
            let ambient_color_temperature: Double
        }

        struct Exposure: Codable {
            /// Seconds. From `frame.camera.exposureDuration`.
            let exposure_duration_seconds: Double
            /// Stops applied by ARKit, from `frame.camera.exposureOffset`.
            let exposure_offset_stops: Double
        }

        struct ExifData: Codable {
            let iso: Double?
            let shutter_speed_seconds: Double?
            /// White balance gains as RGB multipliers, when available.
            let white_balance_rgb_gains: [Double]?
            /// Lens position in [0,1] from camera AF system, when available.
            let lens_position: Double?
        }
    }
}

// MARK: - CapturedFrame (in-memory representation)

/// One frame the iOS coordinator accepted. Image and depth payloads are
/// staged to disk by FrameLogger so memory stays bounded across long
/// sessions; ManifestUploader reads them on demand at upload time.
struct CapturedFrame: Equatable, Hashable {
    let id: Int
    let timestamp: Date

    // On-disk staging. `jpegURL` is nil only for rejected-frame records.
    let jpegURL: URL?
    let depthURL: URL?
    let smoothedDepthURL: URL?
    let depthConfidenceURL: URL?
    let featurePointsURL: URL?

    // Image dimensions of the JPEG.
    let width: Int
    let height: Int

    // ARKit camera matrices, serialised as 4×4 / 3×3 row-major arrays.
    let cameraTransformRows: [[Double]]
    let cameraIntrinsicsRows: [[Double]]

    // ARKit tracking signals.
    let trackingState: String           // "normal" | "limited" | "notAvailable"
    let trackingReason: String?         // limited-reason; nil if tracking is normal
    let worldMappingStatus: String      // "notAvailable" | "limited" | "extending" | "mapped"
    let lightAmbientIntensity: Double?
    let lightAmbientColorTemperature: Double?
    let rawFeaturePointsCount: Int

    // Depth flags.
    let hasSceneDepth: Bool             // true iff depthURL != nil

    // Quality scores [0..1] (blurScore is raw Laplacian variance).
    let poseQualityScore: Double
    let blurScore: Double
    let coverageScore: Double
    let acceptedForTraining: Bool

    /// True when the JPEG came from `captureHighResolutionFrame` rather
    /// than the preview stream.
    let capturedHighResolution: Bool

    /// Apple radiometric data — used to normalize colors across frames.
    let exposureDurationSeconds: Double?
    let exposureOffsetStops: Double?

    /// EXIF dict from ARFrame.exifData, when present.
    let exifISO: Double?
    let exifShutterSeconds: Double?
    let exifWhiteBalanceRGBGains: [Double]?
    let exifLensPosition: Double?

    /// Set when this CapturedFrame represents a REJECTED frame (logged for
    /// negative-training signal). The JPEG/depth URLs are nil in that case.
    let rejectReason: String?
}

extension CapturedFrame {

    /// Filenames the laptop server expects for this frame (matches
    /// CAPTURE_PROTOCOL.md frames/, depth/, depth_smoothed/ layout).
    var manifestImagePath: String?     { jpegURL == nil ? nil : "frames/\(Self.basename(id: id, ext: "jpg"))" }
    var manifestDepthPath: String?     { hasSceneDepth ? "depth/\(Self.basename(id: id, ext: "bin"))" : nil }
    var manifestSmoothedDepthPath: String? {
        smoothedDepthURL == nil ? nil : "depth_smoothed/\(Self.basename(id: id, ext: "bin"))"
    }
    var manifestConfidencePath: String? {
        depthConfidenceURL == nil ? nil : "depth_confidence/\(Self.basename(id: id, ext: "bin"))"
    }
    var manifestFeaturePointsPath: String? {
        featurePointsURL == nil ? nil : "feature_points/\(Self.basename(id: id, ext: "bin"))"
    }

    static func basename(id: Int, ext: String) -> String {
        String(format: "frame_%06d.\(ext)", id)
    }

    /// Convert into the on-the-wire Manifest.Frame.
    func toManifestFrame() -> Manifest.Frame {
        let lightEstimate: Manifest.Frame.LightEstimate? = {
            guard let intensity = lightAmbientIntensity,
                  let temp = lightAmbientColorTemperature
            else { return nil }
            return .init(ambient_intensity: intensity, ambient_color_temperature: temp)
        }()
        let exposure: Manifest.Frame.Exposure? = {
            guard let dur = exposureDurationSeconds,
                  let off = exposureOffsetStops
            else { return nil }
            return .init(exposure_duration_seconds: dur, exposure_offset_stops: off)
        }()
        let exif: Manifest.Frame.ExifData? = {
            if exifISO == nil, exifShutterSeconds == nil,
               exifWhiteBalanceRGBGains == nil, exifLensPosition == nil {
                return nil
            }
            return .init(
                iso: exifISO,
                shutter_speed_seconds: exifShutterSeconds,
                white_balance_rgb_gains: exifWhiteBalanceRGBGains,
                lens_position: exifLensPosition
            )
        }()
        return Manifest.Frame(
            frame_id: id,
            timestamp: timestamp.timeIntervalSince1970,
            image_path: manifestImagePath ?? "",
            camera_transform_world: cameraTransformRows,
            camera_intrinsics: cameraIntrinsicsRows,
            image_width: width,
            image_height: height,
            tracking_state: trackingState,
            tracking_reason: trackingReason,
            world_mapping_status: worldMappingStatus,
            light_estimate: lightEstimate,
            raw_feature_points_count: rawFeaturePointsCount,
            has_scene_depth: hasSceneDepth,
            scene_depth_path: manifestDepthPath,
            smoothed_scene_depth_path: manifestSmoothedDepthPath,
            depth_confidence_path: manifestConfidencePath,
            feature_points_path: manifestFeaturePointsPath,
            pose_quality_score: poseQualityScore,
            blur_score: blurScore,
            coverage_score: coverageScore,
            captured_high_resolution: capturedHighResolution,
            exposure: exposure,
            exif: exif,
            accepted_for_training: acceptedForTraining,
            reject_reason: rejectReason
        )
    }
}

/// What the laptop returns from POST /upload.
struct UploadSummary: Equatable, Hashable {
    let runID: String
    let framesReceived: Int
    let depthReceived: Int
    let trackingBreakdown: [String: Int]
}
