//
//  DeviceCapability.swift
//  AR-Layer 2 — capability probe.
//
//  Decides at runtime whether the device supports world tracking, LiDAR
//  scene depth, and scene reconstruction. Picks the right ARKit video
//  format based on the user's 60/30 Hz preference and the recommended
//  high-resolution path. Result feeds ARCaptureCoordinator's config.
//

import ARKit
import Foundation

struct DeviceCapability: Equatable {
    let supportsARWorldTracking: Bool
    let supportsSceneDepth: Bool
    let supportsSmoothedSceneDepth: Bool
    let supportsSceneReconstruction: Bool
    let supportsHighResolutionFrameCapture: Bool
    /// Selected ARConfiguration video format for 60 Hz; nil → 60 Hz unsupported.
    let videoFormat60Hz: ARConfiguration.VideoFormat?
    /// Selected ARConfiguration video format for 30 Hz.
    let videoFormat30Hz: ARConfiguration.VideoFormat?
    /// Apple-recommended high-res still-capture format (iOS 16+).
    let highResolutionStillFormat: ARConfiguration.VideoFormat?

    /// Probe the running device. Cheap (no ARSession started yet).
    static func probe() -> DeviceCapability {
        let supportsWorld = ARWorldTrackingConfiguration.isSupported
        let supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        let supportsSmoothed = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
        let supportsRecon = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)

        // Filter the supported video formats by frame rate. Take the largest
        // resolution available for each rate (Apple sorts the array but we
        // sort defensively).
        let allFormats = ARWorldTrackingConfiguration.supportedVideoFormats
        let by60: [ARConfiguration.VideoFormat] = allFormats
            .filter { $0.framesPerSecond >= 60 }
            .sorted { lhs, rhs in
                lhs.imageResolution.width * lhs.imageResolution.height
                    > rhs.imageResolution.width * rhs.imageResolution.height
            }
        let by30: [ARConfiguration.VideoFormat] = allFormats
            .filter { ($0.framesPerSecond >= 29) && ($0.framesPerSecond < 60) }
            .sorted { lhs, rhs in
                lhs.imageResolution.width * lhs.imageResolution.height
                    > rhs.imageResolution.width * rhs.imageResolution.height
            }

        // High-res recommended format (iOS 16+).
        let highResFormat: ARConfiguration.VideoFormat?
        if #available(iOS 16.0, *) {
            highResFormat = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing
        } else {
            highResFormat = nil
        }

        return DeviceCapability(
            supportsARWorldTracking: supportsWorld,
            supportsSceneDepth: supportsDepth,
            supportsSmoothedSceneDepth: supportsSmoothed,
            supportsSceneReconstruction: supportsRecon,
            supportsHighResolutionFrameCapture: highResFormat != nil,
            videoFormat60Hz: by60.first,
            videoFormat30Hz: by30.first ?? allFormats.last,  // any 30+ fps as fallback
            highResolutionStillFormat: highResFormat
        )
    }

    /// Pick the video format to use given the user's preferred capture
    /// cadence. Falls back if the preferred Hz isn't supported.
    func videoFormat(forPreferredHz hz: Int) -> ARConfiguration.VideoFormat? {
        if hz >= 60, let f = videoFormat60Hz { return f }
        if let f = videoFormat30Hz { return f }
        return videoFormat60Hz   // last resort
    }

    /// Human-readable summary used by JoinView's HW chip.
    var summary: String {
        var bits: [String] = []
        bits.append(supportsSceneDepth ? "LiDAR" : "no LiDAR")
        bits.append(supportsSceneReconstruction ? "mesh" : "no mesh")
        bits.append(supportsHighResolutionFrameCapture ? "highres" : "preview-res")
        bits.append(videoFormat60Hz != nil ? "60Hz" : "30Hz only")
        return bits.joined(separator: " · ")
    }

    /// What we put into manifest.device.ar_world_tracking_configuration
    /// at session-start time.
    func toManifestDevice(usingFormat format: ARConfiguration.VideoFormat?,
                          enabledSemantics: [String],
                          sceneReconstructionMode: String) -> Manifest.ARConfig {
        let res = format?.imageResolution ?? .zero
        let fps = Int(format?.framesPerSecond ?? 0)
        return Manifest.ARConfig(
            video_format: .init(width: Int(res.width), height: Int(res.height), fps: fps),
            frame_semantics: enabledSemantics,
            plane_detection: ["horizontal", "vertical"],
            scene_reconstruction: sceneReconstructionMode
        )
    }
}
