//
//  CaptureView.swift
//  AR-Layer 2 — live ARKit scan screen.
//
//  Hosts an ARSCNView preview surface, drives the ARCaptureCoordinator,
//  shows the dark-luxury HUD: top status bar + tracking chip + radial
//  coverage mask + bottom progress dock.
//

import ARKit
import SwiftUI

struct CaptureView: View {
    let descriptor: SessionDescriptor
    let host: String
    let policy: CapturePolicy

    @EnvironmentObject var router: Router
    @StateObject private var coordinator = ARCaptureCoordinator()
    /// AR-Layer 2.5 — live mesh overlay. The Gold tier (default, free)
    /// uses TexturedMeshRenderer which projects the camera feed onto
    /// each anchor for the "filling-in with real-world appearance"
    /// effect. Other tiers (Platinum/Max/On-Mobile) reuse this same
    /// renderer for their capture phase — they differ only in *post*-
    /// capture playback. The legacy flat-color MeshLiveRenderer is kept
    /// in the codebase as a non-Gold fallback for future tiers that
    /// want to suppress textured sampling.
    @StateObject private var texturedMesh = TexturedMeshRenderer()

    @State private var error: String?
    @State private var configured = false
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt = Date()
    @State private var ticker: Timer?
    @State private var sectorFractions: [Double] = Array(repeating: 0, count: 8)

    /// Phase 2 — atlas-baked mesh handed to MeshExplorerView. Populated
    /// when the user taps "Explore Mesh" and the bake completes.
    @State private var bakedMesh: BakedMesh? = nil
    @State private var showingExplorer: Bool = false
    /// True while MeshAtlasBaker.bake is running on a background actor.
    /// CaptureView shows a "BAKING TEXTURES" scrim during this window;
    /// AR session is already paused so the GPU is free for the bake.
    @State private var isBaking: Bool = false
    @State private var bakeError: String? = nil
    /// Last bake's stats — surfaced to the HUD on success.
    @State private var lastBakeStats: BakeStats? = nil
    /// Live progress label rendered in the baking overlay. The bake fires
    /// (phase, fraction) callbacks on its background thread; the
    /// startBake() main-actor hop translates them into this string.
    @State private var bakeStatusLabel: String = "PREPARING"
    @State private var bakeStatusFraction: Double = 0.0

    var body: some View {
        ZStack {
            preview
            scrim
            hud
            if isBaking { bakingOverlay }
        }
        .ignoresSafeArea()
        .alert("Capture error",
               isPresented: .init(get: { error != nil },
                                  set: { if !$0 { error = nil } })) {
            Button("Back") { router.reset() }
        } message: {
            Text(error ?? "")
        }
        .alert("Bake failed",
               isPresented: .init(get: { bakeError != nil },
                                  set: { if !$0 { bakeError = nil } })) {
            Button("OK") {
                bakeError = nil
                coordinator.resumeFromExploration()
            }
        } message: {
            Text(bakeError ?? "")
        }
        .onAppear {
            coordinator.onFinished = { frames in
                Task { @MainActor in
                    stopTicker()
                    if frames.isEmpty {
                        router.reset()
                    } else {
                        let device = coordinator.manifestDevice()
                        let summary = coordinator.manifestSummary(framesAccepted: frames.count)
                        // Sidecar URLs are only meaningful when their
                        // corresponding export succeeded — gate each.
                        let worldMap = coordinator.didExportWorldMap
                            ? coordinator.worldMapSidecarURL : nil
                        let mesh = coordinator.didExportMesh
                            ? coordinator.meshSidecarURL : nil
                        let rejected = coordinator.didExportRejectedFrames
                            ? coordinator.rejectedFramesSidecarURL : nil
                        router.proceedToUpload(descriptor: descriptor,
                                                host: host,
                                                policy: policy,
                                                frames: frames,
                                                device: device,
                                                summary: summary,
                                                worldMapURL: worldMap,
                                                meshURL: mesh,
                                                rejectedFramesURL: rejected)
                    }
                }
            }
            Task { await start() }
        }
        .onDisappear {
            stopTicker()
            coordinator.stop()
        }
        .fullScreenCover(isPresented: $showingExplorer, onDismiss: {
            // Resume AR scanning where we left off. The world map +
            // anchors are preserved by ARCaptureCoordinator across the
            // pause so the user can keep extending the mesh.
            bakedMesh = nil
            coordinator.resumeFromExploration()
        }) {
            // The bake completed before this cover became eligible to
            // present; bakedMesh is guaranteed non-nil here.
            if let mesh = bakedMesh {
                MeshExplorerView(bakedMesh: mesh)
            } else {
                // Defensive — should never happen.
                Color.black.ignoresSafeArea()
            }
        }
    }

    // MARK: baking overlay

    /// Full-screen scrim shown over the (now-frozen) capture preview while
    /// MeshAtlasBaker runs on a background actor. Reads bakeStatusLabel +
    /// bakeStatusFraction (kept in sync by the bake's progress callback)
    /// so the user sees continuous, honest progress instead of an
    /// indefinite spinner.
    private var bakingOverlay: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: bakeStatusFraction, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(Theme.Color.halo)
                    .frame(width: 200)
                Text(bakeStatusLabel)
                    .font(.system(size: 13, weight: .heavy)).tracking(2.0)
                    .foregroundStyle(.white)
                    .animation(.easeInOut(duration: 0.2), value: bakeStatusLabel)
                Text("\(Int(bakeStatusFraction * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Fusing every captured camera frame into a 4K texture atlas. Phone stays responsive — this takes a few seconds.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
                    .padding(.top, 6)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.Color.halo.opacity(0.45), lineWidth: 0.8)
            )
        }
        .transition(.opacity)
    }

    // MARK: pieces

    private var preview: some View {
        ARSCNViewContainer(session: coordinator.arSession,
                           delegate: texturedMesh)
            .ignoresSafeArea()
    }

    private var scrim: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear],
                           startPoint: .top, endPoint: .center)
            LinearGradient(colors: [.clear, .black.opacity(0.85)],
                           startPoint: .center, endPoint: .bottom)
            RadialGradient(colors: [.clear, Theme.Color.halo.opacity(0.10)],
                           center: .center,
                           startRadius: 100, endRadius: 600)
                .blendMode(.plusLighter)
        }
    }

    private var hud: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            // Coverage mask centred behind the tracking chip.
            ZStack {
                CoverageMaskView(
                    coverageFraction: coordinator.coverageFraction,
                    sectorVisitFractions: sectorFractions
                )
                .frame(width: 280, height: 280)
                VStack(spacing: 12) {
                    Spacer()
                    TrackingChip(guidance: coordinator.guidance)
                }
                .padding(.bottom, 10)
            }
            Spacer()
            bottomDock
        }
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                MonoPill(label: "REC", value: timeString(elapsed))
                Spacer()
                MonoPill(label: "MESH", value: "\(texturedMesh.anchorCount)")
                meshToggleButton
                MonoPill(label: "FRAMES",
                         value: "\(coordinator.capturedCount)/\(policy.frame_budget.target)")
            }
            HStack {
                Text(policy.scan_mode.uppercased())
                    .font(Theme.Font.caption(10)).tracking(1.6)
                    .foregroundStyle(Theme.Color.halo)
                Text("·").foregroundStyle(Theme.Color.textDim)
                Text("\(String(format: "%.1f", policy.distance_band_meters.near))–\(String(format: "%.1f", policy.distance_band_meters.far)) m")
                    .font(Theme.Font.mono(11))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Text(coordinator.trackingStateLabel.uppercased())
                    .font(Theme.Font.mono(10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
            .overlay(Capsule().stroke(Theme.Color.halo.opacity(0.4), lineWidth: 0.8))
        }
        .padding(.horizontal, 18)
        .padding(.top, 60)
    }

    /// Tiny round button that toggles the AR-Layer 2.5 mesh overlay.
    /// Filled with halo when on, hairline ring when off.
    private var meshToggleButton: some View {
        Button {
            texturedMesh.isEnabled.toggle()
        } label: {
            Image(systemName: texturedMesh.isEnabled
                    ? "square.grid.3x3.fill" : "square.grid.3x3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(texturedMesh.isEnabled
                                 ? Theme.Color.ink : Theme.Color.textPrimary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(
                        texturedMesh.isEnabled
                            ? Theme.Color.halo.opacity(0.85)
                            : Color.white.opacity(0.05)
                    )
                )
                .overlay(
                    Circle().stroke(Theme.Color.halo.opacity(0.5),
                                    lineWidth: texturedMesh.isEnabled ? 0 : 0.8)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(texturedMesh.isEnabled
                            ? "Hide mesh overlay" : "Show mesh overlay")
    }

    private var bottomDock: some View {
        VStack(spacing: 12) {
            progressBlock
            // Gold-tier "Explore Mesh" button. Visible after at least a
            // handful of anchors have been textured so it's actually
            // meaningful to walk into. Capture continues underneath.
            if texturedMesh.anchorCount >= 3 {
                exploreButton
            }
            HStack(spacing: 12) {
                GhostButton(title: "Cancel") {
                    coordinator.stop()
                    router.reset()
                }
                AccentHaloButton("Stop & Upload", systemImage: "checkmark.circle.fill") {
                    Task { await coordinator.finishAndDeliver() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 38)
    }

    private var exploreButton: some View {
        Button {
            startBake()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.walk.motion")
                    .font(.system(size: 13, weight: .semibold))
                Text("EXPLORE MESH")
                    .font(.system(size: 12, weight: .heavy)).tracking(1.6)
                MonoPill(label: "GOLD", value: "")
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [.white, Theme.Color.halo],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(Capsule().stroke(Theme.Color.halo, lineWidth: 1.0))
            .shadow(color: Theme.Color.halo.opacity(0.45), radius: 16)
        }
        .buttonStyle(.plain)
    }

    private var progressBlock: some View {
        VStack(spacing: 6) {
            HStack {
                Text("CAPTURING")
                    .font(Theme.Font.caption(11)).tracking(2.0)
                    .foregroundStyle(Theme.Color.textDim)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(Theme.Font.mono(12))
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            ScanningBar()
        }
    }

    private var progress: Double {
        let t = max(1, policy.frame_budget.target)
        return min(1.0, Double(coordinator.capturedCount) / Double(t))
    }

    // MARK: lifecycle

    @MainActor
    private func start() async {
        guard !configured else { return }
        // Drop any stale meshes from a previous (cancelled) session so the
        // overlay starts empty for this run.
        texturedMesh.reset()
        texturedMesh.attach(session: coordinator.arSession)
        do {
            try await coordinator.start(
                sessionID: descriptor.session_id,
                policy: policy,
                cadence: CaptureSettings.cadence()
            )
            configured = true
            startedAt = Date()
            startTicker()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                self.elapsed = Date().timeIntervalSince(startedAt)
                // Pulse sector fractions so the radial mask feels alive.
                // We don't expose per-sector visit counts publicly; approximate
                // via coverageFraction smeared across the sectors.
                let cov = coordinator.coverageFraction
                self.sectorFractions = (0..<8).map { i in
                    // give a slight phase per sector so the HUD shimmers.
                    let phase = sin(Date().timeIntervalSince1970 * 0.9 + Double(i) * 0.4)
                    return min(1.0, cov + 0.06 * phase)
                }
            }
        }
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    // MARK: - Atlas bake

    /// Tap handler for the EXPLORE MESH button.
    ///
    /// Order matters here:
    ///  1. Pause AR — frees GPU for the bake, stops candidate pool mutation.
    ///  2. Snapshot mesh + candidate views (deep-copy where needed).
    ///  3. **Free the live ring buffer** in TexturedMeshRenderer (saves
    ///     ~250 MB of RAM that was only useful while scanning). The live
    ///     overlay rebuilds itself in <2 s after the user dismisses the
    ///     explorer and resumes scanning.
    ///  4. Kick off MeshAtlasBaker on a detached background task. The
    ///     bake fires (phase, fraction) progress callbacks on its
    ///     background thread; we hop them to MainActor for state updates.
    ///  5. When the bake finishes, flip the cover.
    @MainActor
    private func startBake() {
        guard !isBaking else { return }
        coordinator.pauseForExploration()

        let snaps = texturedMesh.snapshotForExplorer()
        let candidates = coordinator.snapshotCandidateViews()

        guard !snaps.isEmpty else {
            bakeError = "No mesh has been captured yet. Sweep the room a bit longer."
            return
        }
        guard let candidates = candidates, !candidates.frames.isEmpty else {
            bakeError = "No candidate camera frames in the pool yet. Sweep slowly past a few surfaces and try again."
            return
        }

        // Free the per-anchor ring buffers before the bake. These are
        // ~250 MB on a typical room — competing with the bake for memory
        // and the largest single pressure source on jetsam.
        texturedMesh.releaseLiveSnapshots()

        isBaking = true
        bakeStatusLabel = "STARTING"
        bakeStatusFraction = 0.0

        Task.detached(priority: .userInitiated) {
            // Progress callback fires on this background thread. Hop to
            // MainActor for every state update — never call SwiftUI
            // @State setters off-main.
            let progress: BakeProgressCallback = { phase, fraction in
                let label = phase.label
                let global: Double
                // Crude global blend: weld 5%, best-view 10%, atlases 80%,
                // finalize 5%. Lets the linear ProgressView feel like
                // continuous progress across phases instead of jumping.
                switch phase {
                case .welding:
                    global = 0.05 * fraction
                case .selectingViews:
                    global = 0.05 + 0.10 * fraction
                case .bakingAtlas(let i, let t):
                    let perAtlas = 0.80 / Double(max(t, 1))
                    global = 0.15 + perAtlas * (Double(i - 1) + fraction)
                case .finalizing:
                    global = 0.95 + 0.05 * fraction
                }
                Task { @MainActor in
                    self.bakeStatusLabel = label
                    self.bakeStatusFraction = global
                }
            }

            do {
                let baked = try MeshAtlasBaker.bake(
                    snapshots: snaps,
                    candidateViews: candidates,
                    onProgress: progress
                )
                await MainActor.run {
                    self.bakedMesh = baked
                    self.lastBakeStats = baked.stats
                    self.isBaking = false
                    self.bakeStatusFraction = 1.0
                    self.showingExplorer = true
                }
            } catch {
                await MainActor.run {
                    self.bakeError = "Atlas bake failed: \(error)"
                    self.isBaking = false
                }
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
