//
//  FrameLogger.swift
//  ARFrame → CapturedFrame, with on-disk staging.
//
//  Writes (per accepted frame):
//    <session_dir>/frames/frame_<id>.jpg              JPEG, 0.85 quality
//    <session_dir>/depth/frame_<id>.bin               16-byte hdr + raw float32 depth
//    <session_dir>/depth_smoothed/frame_<id>.bin      same, optional
//    <session_dir>/depth_confidence/frame_<id>.bin    16-byte hdr + raw uint8 confidence
//    <session_dir>/feature_points/frame_<id>.bin      16-byte hdr + N×20 byte points
//
//  Per-frame files use a 16-byte little-endian header (CAPTURE_PROTOCOL.md §3):
//    Depth / depth_smoothed:  uint32 width, height, stride_bytes, reserved
//    Depth confidence:        uint32 width, height, stride_bytes, reserved (uint8 payload)
//    Feature points:          char[4]='FPTS', uint32 count, uint64 reserved
//                             Then N × { float32 x,y,z, uint64 identifier } = 20 B each.
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
    let depthConfidenceDir: URL
    let featurePointsDir: URL

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(sessionID: String) throws {
        let tmp = FileManager.default.temporaryDirectory
        self.stagingDir = tmp.appendingPathComponent("splattr_capture_\(sessionID)", isDirectory: true)
        self.framesDir = stagingDir.appendingPathComponent("frames", isDirectory: true)
        self.depthDir = stagingDir.appendingPathComponent("depth", isDirectory: true)
        self.depthSmoothedDir = stagingDir.appendingPathComponent("depth_smoothed", isDirectory: true)
        self.depthConfidenceDir = stagingDir.appendingPathComponent("depth_confidence", isDirectory: true)
        self.featurePointsDir = stagingDir.appendingPathComponent("feature_points", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: depthDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: depthSmoothedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: depthConfidenceDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: featurePointsDir, withIntermediateDirectories: true)
    }

    deinit {
        // Best-effort cleanup of temp staging when the logger is dropped.
        try? FileManager.default.removeItem(at: stagingDir)
    }

    /// Stage one accepted frame. Returns nil on file-write failure.
    ///
    /// `timestamp` MUST already be a Unix-epoch seconds value. ARFrame.timestamp
    /// is mach-time seconds since boot — the coordinator converts it before
    /// calling here so on-disk + manifest timestamps are real wall-clock dates.
    ///
    /// `capturedHighResolution` is true when `arFrame` came from
    /// `ARSession.captureHighResolutionFrame(...)` rather than the
    /// preview-resolution didUpdate stream.
    func write(
        id: Int,
        timestamp: TimeInterval,
        arFrame: ARFrame,
        blurScore: Double,
        coverageScore: Double,
        poseQualityScore: Double,
        capturedHighResolution: Bool
    ) -> CapturedFrame? {
        // 1. JPEG
        let jpegURL = framesDir.appendingPathComponent(
            CapturedFrame.basename(id: id, ext: "jpg")
        )
        guard let _ = encodeJPEG(arFrame.capturedImage, to: jpegURL) else {
            return nil
        }

        // 2. Depth + confidence (optional, LiDAR only)
        var depthURL: URL? = nil
        var confidenceURL: URL? = nil
        if let depth = arFrame.sceneDepth {
            let url = depthDir.appendingPathComponent(
                CapturedFrame.basename(id: id, ext: "bin")
            )
            if writeDepth(depth.depthMap, to: url) {
                depthURL = url
            }
            if let conf = depth.confidenceMap {
                let confURL = depthConfidenceDir.appendingPathComponent(
                    CapturedFrame.basename(id: id, ext: "bin")
                )
                if writeConfidence(conf, to: confURL) {
                    confidenceURL = confURL
                }
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

        // 3. Raw feature points (sparse cloud + persistent identifiers).
        var fpURL: URL? = nil
        if let cloud = arFrame.rawFeaturePoints, !cloud.points.isEmpty {
            let url = featurePointsDir.appendingPathComponent(
                CapturedFrame.basename(id: id, ext: "bin")
            )
            if writeFeaturePoints(cloud, to: url) {
                fpURL = url
            }
        }

        // 4. ARKit metadata + radiometric
        let camera = arFrame.camera
        let transformRows = matrix4x4ToRows(camera.transform)
        let intrinsicsRows = matrix3x3ToRows(camera.intrinsics)
        let trackingStateLabel = PoseQuality.trackingStateLabel(camera.trackingState)
        let trackingReason = PoseQuality.trackingReasonLabel(camera.trackingState)
        let mappingLabel = PoseQuality.worldMappingStatusLabel(arFrame.worldMappingStatus)
        let intensity = arFrame.lightEstimate?.ambientIntensity
        let temperature = arFrame.lightEstimate?.ambientColorTemperature
        let featurePointsCount = arFrame.rawFeaturePoints?.points.count ?? 0

        let exifBag = parseExif(arFrame.exifData)

        return CapturedFrame(
            id: id,
            timestamp: Date(timeIntervalSince1970: timestamp),
            jpegURL: jpegURL,
            depthURL: depthURL,
            smoothedDepthURL: smoothedURL,
            depthConfidenceURL: confidenceURL,
            featurePointsURL: fpURL,
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
            acceptedForTraining: true,
            capturedHighResolution: capturedHighResolution,
            exposureDurationSeconds: Double(camera.exposureDuration),
            exposureOffsetStops: Double(camera.exposureOffset),
            exifISO: exifBag.iso,
            exifShutterSeconds: exifBag.shutter,
            exifWhiteBalanceRGBGains: exifBag.wbGains,
            exifLensPosition: exifBag.lensPos,
            rejectReason: nil
        )
    }

    /// Build a CapturedFrame for a REJECTED frame — no JPEG/depth on disk,
    /// just metadata + reject reason. ARCaptureCoordinator stages these into
    /// `rejected_frames.json` so downstream gets the negative-training signal.
    func rejectedRecord(
        id: Int,
        timestamp: TimeInterval,
        arFrame: ARFrame,
        blurScore: Double,
        coverageScore: Double,
        poseQualityScore: Double,
        rejectReason: String
    ) -> CapturedFrame {
        let camera = arFrame.camera
        let transformRows = matrix4x4ToRows(camera.transform)
        let intrinsicsRows = matrix3x3ToRows(camera.intrinsics)
        let trackingStateLabel = PoseQuality.trackingStateLabel(camera.trackingState)
        let trackingReason = PoseQuality.trackingReasonLabel(camera.trackingState)
        let mappingLabel = PoseQuality.worldMappingStatusLabel(arFrame.worldMappingStatus)
        let intensity = arFrame.lightEstimate?.ambientIntensity
        let temperature = arFrame.lightEstimate?.ambientColorTemperature
        let featurePointsCount = arFrame.rawFeaturePoints?.points.count ?? 0
        let exifBag = parseExif(arFrame.exifData)
        return CapturedFrame(
            id: id,
            timestamp: Date(timeIntervalSince1970: timestamp),
            jpegURL: nil,
            depthURL: nil,
            smoothedDepthURL: nil,
            depthConfidenceURL: nil,
            featurePointsURL: nil,
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
            hasSceneDepth: false,
            poseQualityScore: poseQualityScore,
            blurScore: blurScore,
            coverageScore: coverageScore,
            acceptedForTraining: false,
            capturedHighResolution: false,
            exposureDurationSeconds: Double(camera.exposureDuration),
            exposureOffsetStops: Double(camera.exposureOffset),
            exifISO: exifBag.iso,
            exifShutterSeconds: exifBag.shutter,
            exifWhiteBalanceRGBGains: exifBag.wbGains,
            exifLensPosition: exifBag.lensPos,
            rejectReason: rejectReason
        )
    }

    /// World-map sidecar destination (set by ARCaptureCoordinator at end of session).
    var worldMapURL: URL { stagingDir.appendingPathComponent("world_map.arworldmap") }

    /// Where the rejected-frames log lands at session end.
    var rejectedFramesURL: URL { stagingDir.appendingPathComponent("rejected_frames.json") }

    /// Where the sceneReconstruction mesh OBJ lands at session end.
    var meshURL: URL { stagingDir.appendingPathComponent("scene_mesh.obj") }

    /// Total bytes staged across all frames + depth + worldmap. For the HUD.
    func currentDiskBytes() -> Int64 {
        let urls = [
            framesDir, depthDir, depthSmoothedDir,
            depthConfidenceDir, featurePointsDir
        ]
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
        for sidecar in [worldMapURL, rejectedFramesURL, meshURL] {
            let v = try? sidecar.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(v?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Internal: JPEG encode

    private func encodeJPEG(_ pixelBuffer: CVPixelBuffer, to url: URL) -> Int? {
        // Keep the image in ARKit's native sensor orientation (landscape).
        // `camera.imageResolution` and `camera.intrinsics` describe THIS
        // orientation; rotating the JPEG without rotating the matrices
        // breaks any downstream COLMAP / pose-bridge ingest. Frame-quality
        // scoring on the laptop (blur/exposure/motion/dedup) is
        // orientation-independent, so landscape is fine end to end.
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
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

    // MARK: - Internal: confidence-map write

    /// Same 16-byte header as depth, but the payload is uint8 (Apple values
    /// 0/1/2 per ARDepthData.confidenceMap docs).
    private func writeConfidence(_ buffer: CVPixelBuffer, to url: URL) -> Bool {
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

    // MARK: - Internal: raw feature points write

    /// Layout:
    ///   bytes  0..3: ASCII 'FPTS' magic
    ///   bytes  4..7: uint32 LE point count
    ///   bytes  8..15: uint64 LE reserved (zero)
    ///   bytes 16..end: count × { float32 x,y,z (12 B), uint64 identifier (8 B) }
    private func writeFeaturePoints(_ cloud: ARPointCloud, to url: URL) -> Bool {
        let count = min(cloud.points.count, cloud.identifiers.count)
        guard count > 0 else { return false }

        var header = Data(count: 16)
        header.withUnsafeMutableBytes { ptr in
            // "FPTS"
            ptr[0] = 0x46; ptr[1] = 0x50; ptr[2] = 0x54; ptr[3] = 0x53
            let p = ptr.bindMemory(to: UInt32.self)
            p[1] = UInt32(count).littleEndian
            // bytes 8..15 left zero
        }

        var payload = Data()
        payload.reserveCapacity(count * 20)
        for i in 0..<count {
            var x = cloud.points[i].x.bitPattern.littleEndian
            var y = cloud.points[i].y.bitPattern.littleEndian
            var z = cloud.points[i].z.bitPattern.littleEndian
            var id = cloud.identifiers[i].littleEndian
            withUnsafeBytes(of: &x) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &z) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &id) { payload.append(contentsOf: $0) }
        }

        do {
            try (header + payload).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Internal: EXIF parsing

    private struct ExifBag {
        let iso: Double?
        let shutter: Double?
        let wbGains: [Double]?
        let lensPos: Double?
    }

    /// `ARFrame.exifData` is a `[String: Any]` keyed by EXIF/TIFF tag names.
    /// We pull out the values that matter for radiometric normalization.
    /// Tag names map to:
    ///   - "ExposureTime"     → shutter seconds (double)
    ///   - "ISOSpeedRatings"  → [Int] or Int (we take first)
    ///   - "AsShotNeutral"    → [3 Doubles] white-balance neutral RGB
    ///   - "FocusDistance"    → optional Double in meters (rarely populated)
    private func parseExif(_ raw: [String: Any]?) -> ExifBag {
        guard let raw = raw else {
            return ExifBag(iso: nil, shutter: nil, wbGains: nil, lensPos: nil)
        }
        let iso: Double? = {
            if let n = raw["ISOSpeedRatings"] as? Double { return n }
            if let n = raw["ISOSpeedRatings"] as? Int { return Double(n) }
            if let arr = raw["ISOSpeedRatings"] as? [Any], let first = arr.first {
                if let d = first as? Double { return d }
                if let i = first as? Int { return Double(i) }
            }
            return nil
        }()
        let shutter = raw["ExposureTime"] as? Double
        let wb: [Double]? = {
            if let arr = raw["AsShotNeutral"] as? [Double], arr.count == 3 { return arr }
            if let arr = raw["AsShotNeutral"] as? [NSNumber], arr.count == 3 {
                return arr.map { $0.doubleValue }
            }
            return nil
        }()
        let lens = raw["FocusDistance"] as? Double
        return ExifBag(iso: iso, shutter: shutter, wbGains: wb, lensPos: lens)
    }
}
