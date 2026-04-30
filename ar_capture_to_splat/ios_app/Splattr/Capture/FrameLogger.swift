//
//  FrameLogger.swift
//  ARFrame → CapturedFrame, with on-disk staging.
//
//  Writes:
//    <session_dir>/frames/frame_<id>.jpg            JPEG, 0.85 quality
//    <session_dir>/depth/frame_<id>.bin             16-byte header + raw float32
//    <session_dir>/depth_smoothed/frame_<id>.bin    same, optional
//
//  The 16-byte depth header (per CAPTURE_PROTOCOL.md §3) is:
//    uint32 width little-endian
//    uint32 height little-endian
//    uint32 stride_bytes little-endian
//    uint32 reserved (zero)
//  Then `width × height` little-endian float32 values, row-major.
//

import ARKit
import CoreImage
import Foundation
import simd
import UIKit

@MainActor
final class FrameLogger {

    let stagingDir: URL
    let framesDir: URL
    let depthDir: URL
    let depthSmoothedDir: URL

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(sessionID: String) throws {
        let tmp = FileManager.default.temporaryDirectory
        self.stagingDir = tmp.appendingPathComponent("splattr_capture_\(sessionID)", isDirectory: true)
        self.framesDir = stagingDir.appendingPathComponent("frames", isDirectory: true)
        self.depthDir = stagingDir.appendingPathComponent("depth", isDirectory: true)
        self.depthSmoothedDir = stagingDir.appendingPathComponent("depth_smoothed", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: depthDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: depthSmoothedDir, withIntermediateDirectories: true)
    }

    deinit {
        // Best-effort cleanup of temp staging when the logger is dropped.
        try? FileManager.default.removeItem(at: stagingDir)
    }

    /// Stage one accepted frame. Returns nil on file-write failure.
    func write(
        id: Int,
        timestamp: TimeInterval,
        arFrame: ARFrame,
        blurScore: Double,
        coverageScore: Double,
        poseQualityScore: Double
    ) -> CapturedFrame? {
        // 1. JPEG
        let jpegURL = framesDir.appendingPathComponent(
            CapturedFrame.basename(id: id, ext: "jpg")
        )
        guard let jpegSize = encodeJPEG(arFrame.capturedImage, to: jpegURL) else {
            return nil
        }

        // 2. Depth (optional, LiDAR only)
        var depthURL: URL? = nil
        if let depth = arFrame.sceneDepth {
            let url = depthDir.appendingPathComponent(
                CapturedFrame.basename(id: id, ext: "bin")
            )
            if writeDepth(depth.depthMap, to: url) {
                depthURL = url
            }
        }
        var smoothedURL: URL? = nil
        if let depth = arFrame.smoothedSceneDepth {
            let url = depthSmoothedDir.appendingPathComponent(
                CapturedFrame.basename(id: id, ext: "bin")
            )
            if writeDepth(depth.depthMap, to: url) {
                smoothedURL = url
            }
        }

        // 3. ARKit metadata
        let camera = arFrame.camera
        let transformRows = matrix4x4ToRows(camera.transform)
        let intrinsicsRows = matrix3x3ToRows(camera.intrinsics)
        let trackingStateLabel = PoseQuality.trackingStateLabel(camera.trackingState)
        let trackingReason = PoseQuality.trackingReasonLabel(camera.trackingState)
        let mappingLabel = PoseQuality.worldMappingStatusLabel(arFrame.worldMappingStatus)
        let intensity = arFrame.lightEstimate?.ambientIntensity
        let temperature = arFrame.lightEstimate?.ambientColorTemperature
        let featurePointsCount = arFrame.rawFeaturePoints?.points.count ?? 0

        return CapturedFrame(
            id: id,
            timestamp: Date(timeIntervalSince1970: timestamp),
            jpegURL: jpegURL,
            depthURL: depthURL,
            smoothedDepthURL: smoothedURL,
            width: Int(camera.imageResolution.width),
            height: Int(camera.imageResolution.height),
            cameraTransformRows: transformRows,
            cameraIntrinsicsRows: intrinsicsRows,
            trackingState: trackingStateLabel,
            trackingReason: trackingReason,
            worldMappingStatus: mappingLabel,
            lightAmbientIntensity: intensity.map(Double.init),
            lightAmbientColorTemperature: temperature.map(Double.init),
            rawFeaturePointsCount: featurePointsCount,
            hasSceneDepth: depthURL != nil,
            poseQualityScore: poseQualityScore,
            blurScore: blurScore,
            coverageScore: coverageScore,
            acceptedForTraining: true
        )
    }

    /// World-map sidecar destination (set by ARCaptureCoordinator at end of session).
    var worldMapURL: URL { stagingDir.appendingPathComponent("world_map.arworldmap") }

    /// Total bytes staged across all frames + depth + worldmap. For the HUD.
    func currentDiskBytes() -> Int64 {
        let urls = [framesDir, depthDir, depthSmoothedDir]
        var total: Int64 = 0
        let fm = FileManager.default
        for u in urls {
            if let it = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in it {
                    let v = try? f.resourceValues(forKeys: [.fileSizeKey])
                    total += Int64(v?.fileSize ?? 0)
                }
            }
        }
        let v = try? worldMapURL.resourceValues(forKeys: [.fileSizeKey])
        total += Int64(v?.fileSize ?? 0)
        return total
    }

    // MARK: - Internal: JPEG encode

    private func encodeJPEG(_ pixelBuffer: CVPixelBuffer, to url: URL) -> Int? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        // ARKit camera frames come in landscape regardless of device
        // orientation; rotate to portrait so the laptop's frame_quality
        // layer can score them without re-orienting.
        let rotated = ci.oriented(.right)
        guard let cg = ciContext.createCGImage(rotated, from: rotated.extent) else { return nil }
        let ui = UIImage(cgImage: cg)
        guard let data = ui.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return data.count
        } catch {
            return nil
        }
    }

    // MARK: - Internal: depth write

    /// Layout: 16-byte little-endian header + raw float32 row-major pixels.
    private func writeDepth(_ buffer: CVPixelBuffer, to url: URL) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }

        var header = Data(count: 16)
        header.withUnsafeMutableBytes { ptr in
            let p = ptr.bindMemory(to: UInt32.self)
            p[0] = UInt32(width).littleEndian
            p[1] = UInt32(height).littleEndian
            p[2] = UInt32(stride).littleEndian
            p[3] = UInt32(0).littleEndian
        }

        let pixelBytes = stride * height
        let pixelData = Data(bytes: base, count: pixelBytes)

        do {
            try (header + pixelData).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Internal: matrix → rows

    /// simd_float4x4 stores columns. Convert to a 4-row, 4-column row-major
    /// nested array of Doubles for JSON.
    private func matrix4x4ToRows(_ m: simd_float4x4) -> [[Double]] {
        var rows: [[Double]] = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        for r in 0..<4 {
            for c in 0..<4 {
                rows[r][c] = Double(m[c][r])
            }
        }
        return rows
    }

    private func matrix3x3ToRows(_ m: simd_float3x3) -> [[Double]] {
        var rows: [[Double]] = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for r in 0..<3 {
            for c in 0..<3 {
                rows[r][c] = Double(m[c][r])
            }
        }
        return rows
    }
}
