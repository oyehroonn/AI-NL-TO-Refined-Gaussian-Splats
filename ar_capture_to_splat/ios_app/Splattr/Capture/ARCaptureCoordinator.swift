//
//  ARCaptureCoordinator.swift
//  AR-Layer 2 — owns the ARSession, runs the per-frame capture pipeline,
//  publishes UI state, exports the worldMap at session end. Replaces
//  the old AVFoundation-based CameraCapture.swift.
//

import ARKit
import Combine
import Foundation
import SwiftUI
import simd

@MainActor
final class ARCaptureCoordinator: NSObject, ObservableObject {

    // MARK: - Published HUD state

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var capturedCount: Int = 0
    @Published private(set) var coverageFraction: Double = 0
    @Published private(set) var guidance: GuidanceState = .init(label: "preparing", level: .normal)
    @Published private(set) var trackingStateLabel: String = "preparing"
    @Published private(set) var diskBytes: Int64 = 0

    // MARK: - Captured frames (consumed by ManifestUploader)

    /// Every frame the coordinator has produced this session — accepted AND
    /// rejected. ManifestUploader filters by `acceptedForTraining` when it
    /// builds multipart parts; the manifest itself carries both so the
    /// laptop sees rejection reasons.
    private(set) var frames: [CapturedFrame] = []
    /// Subset: only frames with a JPEG/depth on disk to upload.
    var acceptedFrames: [CapturedFrame] {
        frames.filter { $0.acceptedForTraining }
    }
    var rejectedFrames: [CapturedFrame] {
        frames.filter { !$0.acceptedForTraining }
    }

    // MARK: - Session inputs (stored from start(...))

    private var policy: CapturePolicy?
    private var capability: DeviceCapability?
    private var cadence: CaptureCadence = .hz60
    private var sessionID: String = ""

    // MARK: - Internal state

    private(set) var arSession = ARSession()
    private var coverage: CoverageGrid?
    private var qualityGate: QualityGate?
    private let loopDetector = LoopClosureDetector()
    private var frameLogger: FrameLogger?

    /// Concurrent encoding queue so JPEG/depth I/O doesn't block the
    /// ARSession delegate.
    private let encodeQueue = DispatchQueue(label: "splattr.capture.encode",
                                            qos: .userInitiated,
                                            attributes: .concurrent)
    private let frameAppendQueue = DispatchQueue(label: "splattr.capture.append")
    private var nextFrameID: Int = 0
    private var lastAcceptedTransform: simd_float4x4?
    private var lastAcceptedTimestamp: TimeInterval?
    private var lastObservedTimestamp: TimeInterval?
    private var lastObservedPosition: SIMD3<Float>?
    private var lastHUDPushAt: TimeInterval = 0
    private var startedAt: Date = Date()

    /// Wall-clock-to-mach-time bridge. ARFrame.timestamp is mach-time
    /// seconds since system boot, NOT a Unix epoch. We sample
    /// `Date().timeIntervalSince1970 - frame.timestamp` once on the first
    /// observed frame and reuse it for every subsequent frame so on-disk
    /// + manifest timestamps are real wall-clock dates.
    private var unixEpochOffset: TimeInterval = 0
    private var hasUnixEpochOffset: Bool = false

    /// `captureHighResolutionFrame` is best-effort and may fail if another
    /// is in flight. We serialize requests with this flag so we don't
    /// stampede the API; on failure we fall back to the preview frame.
    private var highResInFlight: Bool = false

    /// True when AR-Layer 3 should request HR stills for accepted frames.
    /// Defaults to true on capable devices (set in `start(...)`).
    private var enableHighResolutionStills: Bool = false

    /// World-map sidecar export status — set by finishAndDeliver.
    private(set) var didExportWorldMap: Bool = false
    /// Mesh sidecar export status — set by finishAndDeliver.
    private(set) var didExportMesh: Bool = false
    /// Rejected-frames JSON sidecar export status.
    private(set) var didExportRejectedFrames: Bool = false

    /// Called when the session naturally finishes (target reached / loop closed
    /// / user stop). The argument is the final accepted-frames array.
    var onFinished: (([CapturedFrame]) -> Void)?

    // For Manifest.summary stats.
    private var trackingHistogram: [String: Int] = [:]
    private var mappingHistogram: [String: Int] = [:]
    private var totalFramesObserved: Int = 0

    // MARK: - Lifecycle

    func start(
        sessionID: String,
        policy: CapturePolicy,
        cadence: CaptureCadence
    ) async throws {
        guard !isRunning else { return }
        self.sessionID = sessionID
        self.policy = policy
        self.cadence = cadence

        try await checkCameraPermission()

        let capability = DeviceCapability.probe()
        self.capability = capability
        guard capability.supportsARWorldTracking else {
            throw NSError(
                domain: "Splattr.AR",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "ARWorldTracking unsupported on this device."]
            )
        }

        coverage = CoverageGrid(
            nearMeters: policy.distance_band_meters.near,
            farMeters: policy.distance_band_meters.far
        )
        qualityGate = QualityGate(policy: policy)
        frameLogger = try FrameLogger(sessionID: sessionID)
        frames.removeAll()
        nextFrameID = 0
        lastAcceptedTransform = nil
        lastAcceptedTimestamp = nil
        lastObservedTimestamp = nil
        lastObservedPosition = nil
        trackingHistogram.removeAll()
        mappingHistogram.removeAll()
        totalFramesObserved = 0
        startedAt = Date()
        unixEpochOffset = 0
        hasUnixEpochOffset = false
        highResInFlight = false
        didExportWorldMap = false
        didExportMesh = false
        didExportRejectedFrames = false
        enableHighResolutionStills = capability.supportsHighResolutionFrameCapture
        capturedCount = 0
        coverageFraction = 0
        guidance = .init(label: "warming up", level: .normal)
        diskBytes = 0

        let config = makeConfiguration(
            policy: policy,
            capability: capability,
            cadence: cadence
        )
        arSession.delegate = self
        arSession.delegateQueue = nil  // main; cheap because we offload heavy work
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        arSession.pause()
    }

    /// Called by CaptureView when the user taps "Stop & Upload" or when stop
    /// conditions fire automatically. Exports the worldMap, snapshots the
    /// sceneReconstruction mesh, writes the rejected-frames JSON, then
    /// routes the caller via `onFinished`.
    func finishAndDeliver() async {
        if isRunning { arSession.pause() }
        if let logger = frameLogger {
            // 1. WorldMap sidecar.
            await loopDetector.exportWorldMap(from: arSession,
                                              to: logger.worldMapURL)
            didExportWorldMap = FileManager.default.fileExists(atPath: logger.worldMapURL.path)

            // 2. Mesh sidecar (sceneReconstruction).
            didExportMesh = MeshSerializer.writeOBJ(from: arSession, to: logger.meshURL)

            // 3. Rejected-frames JSON sidecar (negative-training signal).
            didExportRejectedFrames = writeRejectedFramesJSON(to: logger.rejectedFramesURL)
        }
        isRunning = false
        let snapshot = frames
        onFinished?(snapshot)
    }

    /// Encodes every rejected frame's metadata to disk so the laptop can
    /// study WHY frames were filtered out (blur, tracking, cooldown, etc.).
    /// Returns true when the file was written.
    private func writeRejectedFramesJSON(to url: URL) -> Bool {
        let rejected = frames.filter { !$0.acceptedForTraining }
        guard !rejected.isEmpty else { return false }
        let payload: [[String: Any]] = rejected.map { f in
            var dict: [String: Any] = [
                "frame_id":              f.id,
                "timestamp":             f.timestamp.timeIntervalSince1970,
                "tracking_state":        f.trackingState,
                "world_mapping_status":  f.worldMappingStatus,
                "blur_score":            f.blurScore,
                "coverage_score":        f.coverageScore,
                "pose_quality_score":    f.poseQualityScore,
                "raw_feature_points_count": f.rawFeaturePointsCount,
                "reject_reason":         f.rejectReason ?? "unknown",
            ]
            if let r = f.trackingReason { dict["tracking_reason"] = r }
            if let i = f.lightAmbientIntensity { dict["ambient_intensity"] = i }
            if let t = f.lightAmbientColorTemperature { dict["ambient_color_temperature"] = t }
            return dict
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: ["rejected_frames": payload],
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("[Coordinator] rejected_frames write failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Manifest helpers (used by ManifestUploader)

    /// Manifest device descriptor reflecting the running configuration.
    func manifestDevice() -> Manifest.Device {
        let cap = capability ?? DeviceCapability.probe()
        let format: ARConfiguration.VideoFormat? = cap.videoFormat(forPreferredHz: cadence.rawValue)
        var enabledSemantics: [String] = []
        if cap.supportsSceneDepth { enabledSemantics.append("sceneDepth") }
        if cap.supportsSmoothedSceneDepth { enabledSemantics.append("smoothedSceneDepth") }
        let reconLabel = cap.supportsSceneReconstruction ? "meshWithClassification" : "none"
        return Manifest.Device(
            model: UIDevice.current.modelIdentifier,
            os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            lidar_supported: cap.supportsSceneDepth,
            scene_reconstruction_supported: cap.supportsSceneReconstruction,
            ar_world_tracking_configuration: cap.toManifestDevice(
                usingFormat: format,
                enabledSemantics: enabledSemantics,
                sceneReconstructionMode: reconLabel
            )
        )
    }

    func manifestSummary(framesAccepted: Int) -> Manifest.Summary {
        let cov = coverage?.coverageFraction ?? 0
        let weak = coverage?.weakRegions(top: 5) ?? []
        return Manifest.Summary(
            frames_captured: totalFramesObserved,
            frames_kept: framesAccepted,
            duration_seconds: Date().timeIntervalSince(startedAt),
            tracking_state_breakdown: trackingHistogram,
            world_mapping_status_breakdown: mappingHistogram,
            coverage_summary: .init(covered_fraction: cov, weak_regions: weak),
            preview_run: false,
            enhance_run: false
        )
    }

    /// Sidecar file URL for the worldMap. Nil if we haven't started yet.
    var worldMapSidecarURL: URL? { frameLogger?.worldMapURL }

    /// Sidecar URL for the sceneReconstruction OBJ snapshot.
    var meshSidecarURL: URL? { frameLogger?.meshURL }

    /// Sidecar URL for rejected_frames.json.
    var rejectedFramesSidecarURL: URL? { frameLogger?.rejectedFramesURL }

    // MARK: - Permission

    private func checkCameraPermission() async throws {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        if s == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw NSError(
                domain: "Splattr.AR",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Camera permission is required. Enable it in Settings → Splattr."]
            )
        }
    }

    // MARK: - ARWorldTrackingConfiguration

    private func makeConfiguration(
        policy: CapturePolicy,
        capability: DeviceCapability,
        cadence: CaptureCadence
    ) -> ARWorldTrackingConfiguration {
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal, .vertical]
        cfg.isLightEstimationEnabled = true
        cfg.environmentTexturing = .none

        // Frame semantics — depth on Pro / Pro Max; never crash on non-LiDAR.
        var sem: ARConfiguration.FrameSemantics = []
        if capability.supportsSceneDepth, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            sem.insert(.sceneDepth)
        }
        if capability.supportsSmoothedSceneDepth,
           ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            sem.insert(.smoothedSceneDepth)
        }
        cfg.frameSemantics = sem

        // Scene reconstruction (mesh) on supported devices.
        if capability.supportsSceneReconstruction {
            cfg.sceneReconstruction = .meshWithClassification
        }

        // Pick the right video format — 60 Hz preferred, 30 Hz fallback.
        if let fmt = capability.videoFormat(forPreferredHz: cadence.rawValue) {
            cfg.videoFormat = fmt
        }

        return cfg
    }
}

// MARK: - ARSessionDelegate

extension ARCaptureCoordinator: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor [weak self] in
            self?.handle(frame: frame)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.guidance = .init(label: "AR session error: \(error.localizedDescription)",
                                   level: .critical)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.guidance = .init(label: "session interrupted — hold still", level: .warn)
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.guidance = .init(label: "tracking resumed", level: .normal)
        }
    }
}

// MARK: - Per-frame pipeline

@MainActor
extension ARCaptureCoordinator {

    private func handle(frame: ARFrame) {
        guard isRunning,
              let policy = policy,
              let coverage = coverage,
              let gate = qualityGate,
              let logger = frameLogger
        else { return }

        totalFramesObserved += 1
        loopDetector.observe(frame: frame)

        // Compute the wall-clock offset once on the first observed frame.
        // ARFrame.timestamp is mach-time seconds since system boot, so we
        // bridge it to Unix epoch by sampling Date() against the very first
        // frame's timestamp and reusing the offset for every subsequent frame.
        if !hasUnixEpochOffset {
            unixEpochOffset = Date().timeIntervalSince1970 - frame.timestamp
            hasUnixEpochOffset = true
        }

        // Histograms (every observed frame, not just accepted).
        let ts = PoseQuality.trackingStateLabel(frame.camera.trackingState)
        trackingHistogram[ts, default: 0] += 1
        let ws = PoseQuality.worldMappingStatusLabel(frame.worldMappingStatus)
        mappingHistogram[ws, default: 0] += 1

        // Speed estimate from previous frame. Internal time math stays on
        // the mach clock — we only convert to Unix when we hand the
        // timestamp to FrameLogger for the manifest.
        let now = frame.timestamp
        var recentSpeed: Double = 0
        if let lastT = lastObservedTimestamp,
           let lastP = lastObservedPosition,
           now - lastT > 0 {
            let here = frame.camera.transform.translation
            let d = simd_distance(lastP, here)
            recentSpeed = Double(d) / (now - lastT)
        }
        lastObservedTimestamp = now
        lastObservedPosition = frame.camera.transform.translation

        // Quick coverage probe (without committing): would this frame freshen?
        var coverageProbe = coverage
        let probeHit = coverageProbe.observe(cameraTransform: frame.camera.transform)
        let wouldFreshen = probeHit.wasFresh

        // Gate decision — heavy: blur is computed only when we MIGHT accept,
        // skipping it when tracking is bad anyway.
        var blurScore: Double = 0
        var shouldAccept = false
        var rejectReason = "skipped"
        if case .normal = frame.camera.trackingState {
            blurScore = BlurDetector.score(for: frame.capturedImage)
            switch gate.decide(
                trackingState: frame.camera.trackingState,
                blur: blurScore,
                cameraTransform: frame.camera.transform,
                lastAcceptedTransform: lastAcceptedTransform,
                lastAcceptedTimestamp: lastAcceptedTimestamp,
                now: now,
                wouldFreshenCoverage: wouldFreshen
            ) {
            case .accept:
                shouldAccept = true
            case .reject(let r):
                shouldAccept = false
                rejectReason = r
            }
        }

        if shouldAccept {
            // Commit the coverage observation now (reuse the probed copy).
            self.coverage = coverageProbe

            let frameID = nextFrameID; nextFrameID += 1
            let poseScore = PoseQuality.score(
                trackingState: frame.camera.trackingState,
                featurePointsCount: frame.rawFeaturePoints?.points.count ?? 0
            )
            let coverageScore = probeHit.wasFresh ? 1.0 : 0.5

            // FrameLogger.write must run on main (MainActor) but the heavy
            // bytes work happens in CIContext on a worker pool internally,
            // so we just call it here.
            let unixTs = frame.timestamp + unixEpochOffset
            if let captured = logger.write(
                id: frameID,
                timestamp: unixTs,
                arFrame: frame,
                blurScore: blurScore,
                coverageScore: coverageScore,
                poseQualityScore: poseScore
            ) {
                frames.append(captured)
                capturedCount = frames.count
                lastAcceptedTransform = frame.camera.transform
                lastAcceptedTimestamp = now
            }
        } else {
            _ = rejectReason     // available for debug if we want to log
        }

        // HUD throttle.
        if now - lastHUDPushAt > 0.1 {
            lastHUDPushAt = now
            self.coverageFraction = self.coverage?.coverageFraction ?? 0
            self.trackingStateLabel = ts
            self.guidance = GuidanceEngine.evaluate(
                trackingState: frame.camera.trackingState,
                worldMappingStatus: frame.worldMappingStatus,
                coverage: self.coverage ?? coverageProbe,
                framesAccepted: capturedCount,
                framesTarget: policy.frame_budget.target,
                recentSpeedMetersPerSecond: recentSpeed,
                policy: policy
            )
            self.diskBytes = logger.currentDiskBytes()
        }

        // Stop conditions.
        if shouldStop(policy: policy) {
            Task { await self.finishAndDeliver() }
        }
    }

    private func shouldStop(policy: CapturePolicy) -> Bool {
        if capturedCount >= policy.frame_budget.max {
            return true
        }
        if capturedCount >= policy.frame_budget.target {
            return true
        }
        if capturedCount >= policy.frame_budget.min,
           coverageFraction >= 0.85 {
            if policy.coverage_targets.loop_closure_required {
                return loopDetector.loopClosed
            }
            return true
        }
        return false
    }
}

// MARK: - small UIDevice helper (mirrors the one ManifestUploader had)

private extension UIDevice {
    var modelIdentifier: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        let id = mirror.children.compactMap { ch -> String? in
            guard let v = ch.value as? Int8, v != 0 else { return nil }
            return String(UnicodeScalar(UInt8(v)))
        }.joined()
        return id.isEmpty ? UIDevice.current.model : id
    }
}
