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
    /// Observed so the BAKING TEXTURES overlay's progress bar + counters
    /// re-render reactively as the bake's @MainActor pushes land. Same
    /// shared singleton DebugHUD observes — no double-observation issue
    /// because @ObservedObject is read-only and stateless on the view.
    @ObservedObject private var bakeMetrics = BakeMetrics.shared

    @State private var error: String?
    @State private var configured = false
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt = Date()
    @State private var ticker: Timer?
    @State private var sectorFractions: [Double] = Array(repeating: 0, count: 8)

    /// Per-anchor explorer snapshots (Phase 1 path — proven colorful).
    /// Populated when bake is gated off, bake throws, or the bake's own
    /// post-flight diagnostics say it produced grey/sentinel-heavy
    /// output. This is the always-safe fallback render path.
    @State private var explorerSnapshots: [TexturedMeshRenderer.ExplorerSnapshot] = []
    /// Atlas-baked mesh (Phase 2 path — Polycam-class per-face MVS).
    /// Populated only when the bake succeeded AND passed diagnostic
    /// gates. When non-nil, the explorer cover renders this instead.
    @State private var bakedMesh: BakedMesh? = nil
    @State private var showingExplorer: Bool = false
    /// True from the instant we start the bake task until the cover
    /// presents (success or fallback). Drives the BAKING TEXTURES
    /// overlay.
    @State private var isBaking: Bool = false
    /// Bake task handle, retained so it can be cancelled if the user
    /// taps the BAKING TEXTURES overlay's stop button. The bake itself
    /// is not Task.isCancelled-checked mid-flight (GPU command buffers
    /// can't be torn down safely mid-dispatch), so cancellation only
    /// short-circuits the post-bake handoff — we always wait for the
    /// current dispatch to drain.
    @State private var bakeTask: Task<Void, Never>? = nil
    /// Only set when the user-actionable case "no mesh captured yet"
    /// fires. Bake failures fall back SILENTLY to Phase 1 — the user
    /// should never see "bake failed" because the bake is invisible UX
    /// from their perspective.
    @State private var bakeError: String? = nil

    var body: some View {
        ZStack {
            preview
            scrim
            hud
            // Debug HUD overlays everything when DebugMode is enabled;
            // self-hides otherwise. Lives at top-trailing.
            VStack {
                HStack {
                    Spacer()
                    DebugHUD()
                }
                Spacer()
            }
        }
        .ignoresSafeArea()
        .alert("Capture error",
               isPresented: .init(get: { error != nil },
                                  set: { if !$0 { error = nil } })) {
            Button("Back") { router.reset() }
        } message: {
            Text(error ?? "")
        }
        .alert("Explore",
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
            explorerSnapshots = []
            bakedMesh = nil
            coordinator.resumeFromExploration()
        }) {
            // Prefer the atlas-baked render if the bake produced one
            // that passed diagnostics; otherwise fall back to the
            // per-anchor Phase 1 path.
            if let baked = bakedMesh {
                MeshExplorerView(baked: baked)
            } else {
                MeshExplorerView(snapshots: explorerSnapshots)
            }
        }
        // BAKING TEXTURES progress overlay — only shown while the bake
        // task is in flight. SwiftUI fades it out when isBaking flips
        // back to false (either bake succeeded, fell back, or hit the
        // memory guard pre-flight).
        .overlay {
            if isBaking { bakingOverlay }
        }
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
            startExploration()
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

    // MARK: - Baking overlay
    //
    // Shown while `isBaking == true`. Reads BakeMetrics for the phase
    // label + fraction so the progress feels honest (it advances as
    // each sub-chunk commits, not on a fake timer). No Cancel button:
    // the GPU command-buffer dispatches can't be safely torn down
    // mid-flight, and a typical room bakes in ~5-15 s. Instead we
    // expose the diagnostic numbers in real time so the dev knows
    // exactly what's happening.

    @ViewBuilder
    private var bakingOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Text("BAKING TEXTURES")
                    .font(.system(size: 12, weight: .heavy)).tracking(2.4)
                    .foregroundStyle(Theme.Color.halo)
                Text(bakeMetrics.phase.uppercased())
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                ProgressView(value: bakeMetrics.phaseProgress)
                    .progressViewStyle(.linear)
                    .tint(Theme.Color.halo)
                    .frame(maxWidth: 240)
                bakingStatsRows
                Spacer()
                Text("BAKE IS NOT INTERRUPTIBLE — IT WILL FINISH SHORTLY.")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 38)
            }
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    /// Live counters fed by BakeMetrics. Reads via the shared singleton
    /// each time SwiftUI re-evaluates — fine because the overlay is
    /// re-rendered on every BakeMetrics @Published change.
    @ViewBuilder
    private var bakingStatsRows: some View {
        VStack(spacing: 6) {
            statRow("triangles",
                    bakeMetrics.totalTriangles > 0
                    ? "\(bakeMetrics.totalTriangles)" : "—")
            statRow("atlases",
                    bakeMetrics.totalAtlases > 0
                    ? "\(bakeMetrics.totalAtlases)" : "—")
            statRow("last sub",
                    bakeMetrics.lastSubChunkMs > 0
                    ? String(format: "%.1f ms", bakeMetrics.lastSubChunkMs)
                    : "—")
            if bakeMetrics.lastChosenSentinelFraction >= 0 {
                statRow("sentinel",
                        String(format: "%.1f%%",
                               bakeMetrics.lastChosenSentinelFraction * 100))
            }
            if bakeMetrics.lastAtlasGreyFraction >= 0 {
                statRow("atlas grey",
                        String(format: "%.1f%%",
                               bakeMetrics.lastAtlasGreyFraction * 100))
            }
        }
        .padding(.top, 10)
    }

    private func statRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k.uppercased())
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(v)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(maxWidth: 220)
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

    // MARK: - Atlas bake — defense-in-depth EXPLORE MESH flow
    //
    // The tap handler dispatches between two render paths:
    //
    //   Phase 1 (always safe) — per-anchor UIImage textures. Proven by
    //     the bed-corner shot. Presents synchronously.
    //
    //   Phase 2 (atlas bake)  — Polycam-class per-face MVS via
    //     MeshAtlasBaker. Higher fidelity ceiling, but historically
    //     fragile (shipped grayscale across 7 fix attempts). Gated on
    //     DebugMode + multiple pre-flight and post-flight diagnostic
    //     checks. ANY failure mode silently falls back to Phase 1 —
    //     the user must never see "bake failed."
    //
    // Pre-flight checks (Phase 2 only):
    //   - DebugMode.isEnabled (kill-switch + signal that user expects
    //     bake metrics in the log)
    //   - snapshots.count > 0  (no mesh captured at all)
    //   - candidateViews ≥ 5   (need enough source frames to pick from)
    //   - free memory ≥ 500MB  (bake peak is ~144 + 64*(N-1) MB)
    //
    // Post-flight checks (Phase 2 only):
    //   - trianglesWithView / triangleCount ≥ 0.5
    //     (else best-view kernel rejected too many — atlas mostly grey)
    //   - BakeMetrics.lastAtlasGreyFraction < 0.5
    //     (else atlas literally measured grey — kernel never sampled)
    //
    // Exception fallback: any throw → silent Phase 1.

    /// Free-memory guard. Atlas bake peak for a 200K-triangle 4-atlas
    /// scene is ~336 MB per `MeshAtlasBaker.swift` header comment.
    /// We require 500 MB headroom so the bake plus any concurrent
    /// ARKit / SCN allocations don't push the process over the
    /// jetsam threshold mid-flight.
    private static let minFreeBytesForBake: UInt64 = 500 * 1024 * 1024
    private static let minCandidateViewsForBake: Int = 5
    private static let minTriangleCoverageForBake: Double = 0.5
    private static let maxAtlasGreyFractionForBake: Double = 0.5

    @MainActor
    private func startExploration() {
        coordinator.pauseForExploration()
        let snaps = texturedMesh.snapshotForExplorer()
        guard !snaps.isEmpty else {
            bakeError = "No mesh has been captured yet. Sweep the room a bit longer."
            // Genuine user-actionable case — resume AR so they can keep scanning.
            return
        }

        // Decide path. Phase 1 if any pre-flight check fails.
        let decision = decideBakePath(snapshots: snaps)
        DebugLog.shared.info("explorer",
            "EXPLORE pressed: anchors=\(snaps.count) → decision=\(decision.label)")

        switch decision {
        case .phaseOne(let reason):
            if let reason = reason {
                DebugLog.shared.info("explorer", "phase1 reason: \(reason)")
            }
            presentPhase1(snapshots: snaps)
        case .phaseTwo(let candidates):
            runBakeFlow(snapshots: snaps, candidates: candidates)
        }
    }

    /// What to do next. .phaseOne always succeeds. .phaseTwo carries the
    /// CandidateViewSnapshot already vended by the coordinator so the
    /// caller doesn't re-fetch it (which would risk a race with anything
    /// touching the pool).
    private enum ExploreDecision {
        case phaseOne(reason: String?)
        case phaseTwo(candidates: CandidateViewSnapshot)
        var label: String {
            switch self {
            case .phaseOne(let r): return "phase1(\(r ?? "default"))"
            case .phaseTwo:        return "phase2(bake)"
            }
        }
    }

    @MainActor
    private func decideBakePath(
        snapshots: [TexturedMeshRenderer.ExplorerSnapshot]
    ) -> ExploreDecision {
        guard DebugMode.isEnabled else {
            return .phaseOne(reason: "DebugMode off")
        }
        guard let candidates = coordinator.snapshotCandidateViews() else {
            return .phaseOne(reason: "no CandidateViewPool snapshot")
        }
        guard candidates.frames.count >= Self.minCandidateViewsForBake else {
            return .phaseOne(reason: "only \(candidates.frames.count) candidate views " +
                                    "(need \(Self.minCandidateViewsForBake))")
        }
        let freeBytes = UInt64(os_proc_available_memory())
        guard freeBytes >= Self.minFreeBytesForBake else {
            return .phaseOne(reason: "free memory " +
                "\(freeBytes / 1024 / 1024) MB < \(Self.minFreeBytesForBake / 1024 / 1024) MB")
        }
        return .phaseTwo(candidates: candidates)
    }

    /// Synchronous Phase 1 presentation. Used when bake is gated off,
    /// when any pre-flight check fails, OR when a bake completes /
    /// throws / produces grey output (silent fallback).
    @MainActor
    private func presentPhase1(snapshots: [TexturedMeshRenderer.ExplorerSnapshot]) {
        texturedMesh.releaseLiveSnapshots()
        bakedMesh = nil
        explorerSnapshots = snapshots
        showingExplorer = true
    }

    /// Run the bake on a background task. Updates BakeMetrics for the
    /// HUD; presents either the baked explorer or falls back to Phase 1
    /// based on post-flight diagnostics.
    @MainActor
    private func runBakeFlow(
        snapshots: [TexturedMeshRenderer.ExplorerSnapshot],
        candidates: CandidateViewSnapshot
    ) {
        // Free ring buffers up-front so the bake has memory headroom.
        // The snapshots we already deep-copied retain everything the
        // explorer needs for fallback.
        texturedMesh.releaseLiveSnapshots()
        BakeMetrics.shared.reset()
        BakeMetrics.shared.phase = "starting"
        isBaking = true

        bakeTask = Task.detached(priority: .userInitiated) {
            let baked: BakedMesh?
            do {
                let result = try MeshAtlasBaker.bake(
                    snapshots: snapshots,
                    candidateViews: candidates,
                    onProgress: { phase, frac in
                        Task { @MainActor in
                            BakeMetrics.shared.phase = phase.label
                            BakeMetrics.shared.phaseProgress = frac
                        }
                    }
                )
                baked = result
            } catch {
                DebugLog.shared.error("explorer",
                    "bake threw: \(error.localizedDescription) → falling back to phase1")
                baked = nil
            }

            await MainActor.run {
                isBaking = false
                bakeTask = nil
                guard !Task.isCancelled else {
                    DebugLog.shared.info("explorer",
                        "bake cancelled → falling back to phase1")
                    presentPhase1(snapshots: snapshots)
                    return
                }
                guard let baked = baked else {
                    presentPhase1(snapshots: snapshots)
                    return
                }
                // Post-flight gates.
                let coverage = Double(baked.stats.trianglesWithView) /
                               Double(max(1, baked.stats.triangleCount))
                let greyFraction = BakeMetrics.shared.lastAtlasGreyFraction
                if coverage < Self.minTriangleCoverageForBake {
                    DebugLog.shared.warn("explorer",
                        "bake produced only \(String(format: "%.1f%%", coverage * 100)) " +
                        "triangle coverage (need ≥ \(Int(Self.minTriangleCoverageForBake * 100))%) " +
                        "→ falling back to phase1")
                    presentPhase1(snapshots: snapshots)
                    return
                }
                if greyFraction > Self.maxAtlasGreyFractionForBake {
                    DebugLog.shared.warn("explorer",
                        "atlas grey-fallback fraction " +
                        "\(String(format: "%.1f%%", greyFraction * 100)) " +
                        "exceeds threshold → falling back to phase1")
                    presentPhase1(snapshots: snapshots)
                    return
                }
                // Bake passed all gates — present the atlas explorer.
                DebugLog.shared.info("explorer",
                    "bake accepted: coverage=\(String(format: "%.1f%%", coverage * 100)) " +
                    "greyFrac=\(String(format: "%.1f%%", max(0, greyFraction) * 100))")
                explorerSnapshots = snapshots   // retained for fallback if dismissed-and-re-opened
                bakedMesh = baked
                showingExplorer = true
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
