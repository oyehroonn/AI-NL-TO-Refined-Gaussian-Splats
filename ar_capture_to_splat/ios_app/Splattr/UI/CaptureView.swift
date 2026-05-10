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

    /// Per-anchor explorer snapshots (Phase 1 path — proven colorful).
    /// Populated synchronously when the user taps "Explore Mesh" — no
    /// bake step, no overlay, instant cover present.
    @State private var explorerSnapshots: [TexturedMeshRenderer.ExplorerSnapshot] = []
    @State private var showingExplorer: Bool = false
    @State private var bakeError: String? = nil
    @State private var hasExploredBefore: Bool = false
    @State private var showResumeBanner: Bool = false

    var body: some View {
        ZStack {
            preview
            scrim
            roomPlanOverlay
            hud
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
            coordinator.resumeFromExploration()
            if hasExploredBefore {
                presentResumeBanner()
            }
        }) {
            MeshExplorerView(
                snapshots: explorerSnapshots,
                preferredSpawnEyePosition: coordinator.recordingStartWorldPosition
            )
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

    private var roomPlanOverlay: some View {
        GeometryReader { proxy in
            let highlightedIDs = Set(
                texturedMesh.roomPlanObjectCoverage(for: coordinator.roomPlanObjects)
                    .filter(\.needsMoreCoverage)
                    .map(\.id)
            )
            let overlays = coordinator.projectedRoomPlanOverlays(
                viewportSize: proxy.size,
                highlighting: highlightedIDs
            )
            ZStack {
                ForEach(overlays) { overlay in
                    RoomPlanObjectOverlayView(overlay: overlay)
                }
            }
            .allowsHitTesting(false)
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
                if let hint = texturedMesh.weakAreaHint {
                    WeakAreaPromptView(hint: hint)
                        .frame(width: 280, height: 280)
                }
                VStack(spacing: 12) {
                    Spacer()
                    TrackingChip(guidance: coordinator.guidance)
                    if texturedMesh.surfaceCoverage.hasAnyData {
                        SurfaceCoverageStatsView(summary: texturedMesh.surfaceCoverage)
                    }
                    if let objectPrompt = roomPlanCoveragePrompt {
                        RoomPlanPromptPill(text: objectPrompt)
                    } else if let instruction = coordinator.roomPlanInstructionLabel,
                              coordinator.roomPlanIsRunning {
                        RoomPlanPromptPill(text: instruction)
                    }
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
            if showResumeBanner {
                Text("Resumed scan — \(Int(coordinator.coverageFraction * 100))% covered")
                    .font(Theme.Font.mono(10))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
                    .overlay(Capsule().stroke(Theme.Color.halo.opacity(0.35), lineWidth: 0.8))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
            // Gate Explore until the scan has enough textured anchors AND a
            // room-sized captured volume so the first-person walk is stable.
            if texturedMesh.explorerReadiness.isReady {
                exploreButton
            } else {
                Text(explorerReadinessLabel)
                    .font(Theme.Font.mono(11))
                    .foregroundStyle(Theme.Color.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
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

    // MARK: - Exploration

    /// Tap handler for the EXPLORE MESH button.
    ///
    /// Per-anchor rendering path (Phase 1, proven colorful in the bed-
    /// corner shot). Synchronous: pause AR → snapshot → flip cover. No
    /// bake, no overlay, no progress bar. Cover presents within a frame.
    /// MeshExplorerView builds the per-anchor scene + coarse-welded
    /// physics body in its makeUIView.
    @MainActor
    private func startExploration() {
        showResumeBanner = false
        coordinator.pauseForExploration()
        let candidateViews = coordinator.snapshotCandidateViews()
        let snaps = texturedMesh.snapshotForExplorer(candidateViews: candidateViews)
        guard !snaps.isEmpty else {
            bakeError = "No mesh has been captured yet. Sweep the room a bit longer."
            return
        }
        explorerSnapshots = snaps
        hasExploredBefore = true
        showingExplorer = true
    }

    @MainActor
    private func presentResumeBanner() {
        showResumeBanner = true
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    showResumeBanner = false
                }
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var roomPlanCoveragePrompt: String? {
        texturedMesh.roomPlanCoveragePrompt(for: coordinator.roomPlanObjects)
    }

    private var explorerReadinessLabel: String {
        let readiness = texturedMesh.explorerReadiness
        if !readiness.hasEnoughTexturedAnchors {
            return "Coverage \(readiness.texturedAnchorCount)/\(TexturedMeshRenderer.ExplorerReadiness.requiredTexturedAnchorCount) textured anchors — keep scanning"
        }

        let volume = String(format: "%.1f", readiness.capturedVolumeCubicMeters)
        let minimum = String(format: "%.1f", TexturedMeshRenderer.ExplorerReadiness.minimumCapturedVolumeCubicMeters)
        return "Coverage volume \(volume)/\(minimum) m3 — keep scanning"
    }
}

private struct SurfaceCoverageStatsView: View {
    let summary: TexturedMeshRenderer.SurfaceCoverageSummary

    var body: some View {
        HStack(spacing: 8) {
            statPill(label: "WALLS", fraction: summary.wallFraction)
            statPill(label: "FLOOR", fraction: summary.floorFraction)
            statPill(label: "CEIL", fraction: summary.ceilingFraction)
        }
    }

    private func statPill(label: String, fraction: Double) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color(for: fraction))
                .frame(width: 5, height: 5)
            Text("\(label) \(Int(fraction * 100))%")
                .font(Theme.Font.mono(10))
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            Capsule().stroke(color(for: fraction).opacity(0.45), lineWidth: 0.8)
        )
    }

    private func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.30:
            return Theme.Color.danger
        case ..<0.70:
            return Theme.Color.halo
        default:
            return Theme.Color.success
        }
    }
}

private struct WeakAreaPromptView: View {
    let hint: TexturedMeshRenderer.WeakAreaHint

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let x = width * hint.normalizedX
            let y = height * hint.normalizedY

            ZStack {
                if hint.isOnScreen {
                    ZStack {
                        Circle()
                            .stroke(Theme.Color.halo, lineWidth: 2)
                            .frame(width: 34, height: 34)
                            .shadow(color: Theme.Color.halo.opacity(0.7), radius: 10)
                        Circle()
                            .trim(from: 0, to: hint.dwellProgress)
                            .stroke(
                                Theme.Color.success,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .frame(width: 42, height: 42)
                            .rotationEffect(.degrees(-90))
                        Circle()
                            .fill(Theme.Color.halo.opacity(0.16))
                            .frame(width: 18, height: 18)
                    }
                    .position(x: x, y: y)
                } else {
                    Image(systemName: arrowSymbol)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.Color.halo)
                        .shadow(color: Theme.Color.halo.opacity(0.7), radius: 10)
                        .position(x: x, y: y)
                }

                Text(hint.label.uppercased())
                    .font(Theme.Font.caption(10))
                    .tracking(1.4)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                    )
                    .overlay(
                        Capsule().stroke(Theme.Color.halo.opacity(0.45), lineWidth: 0.8)
                    )
                    .position(x: labelX(width: width, pointX: x), y: max(18, y - 24))
            }
        }
    }

    private var arrowSymbol: String {
        switch (hint.horizontalDirection, hint.verticalDirection) {
        case (-1, 1): return "arrow.up.left.circle.fill"
        case (0, 1): return "arrow.up.circle.fill"
        case (1, 1): return "arrow.up.right.circle.fill"
        case (-1, 0): return "arrow.left.circle.fill"
        case (1, 0): return "arrow.right.circle.fill"
        case (-1, -1): return "arrow.down.left.circle.fill"
        case (0, -1): return "arrow.down.circle.fill"
        case (1, -1): return "arrow.down.right.circle.fill"
        default: return "scope"
        }
    }

    private func labelX(width: CGFloat, pointX: CGFloat) -> CGFloat {
        min(width - 74, max(74, pointX))
    }
}

private struct RoomPlanPromptPill: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.caption(10))
            .tracking(1.4)
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                Capsule().stroke(Theme.Color.electric.opacity(0.45), lineWidth: 0.8)
            )
    }
}

private struct RoomPlanObjectOverlayView: View {
    let overlay: RoomPlanProjectedOverlay

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, style: StrokeStyle(lineWidth: 1.4, dash: [7, 5]))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(borderColor.opacity(0.06))
                )
            Text(overlay.label)
                .font(Theme.Font.mono(10))
                .foregroundStyle(Theme.Color.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Theme.Color.inkRaised.opacity(0.88))
                )
                .overlay(
                    Capsule().stroke(borderColor.opacity(0.55), lineWidth: 0.8)
                )
                .offset(x: 10, y: -12)
        }
        .frame(width: overlay.rect.width, height: overlay.rect.height)
        .position(x: overlay.rect.midX, y: overlay.rect.midY)
        .shadow(color: borderColor.opacity(0.25), radius: 10)
    }

    private var borderColor: Color {
        overlay.needsMoreCoverage ? Theme.Color.halo : Theme.Color.electric
    }
}
