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

    /// Snapshots fed into the post-scan explorer when the user taps the
    /// Explore button. Populated lazily — we only snapshot when they ask,
    /// so the live capture path stays cheap.
    @State private var explorerSnapshots: [TexturedMeshRenderer.ExplorerSnapshot] = []
    @State private var showingExplorer: Bool = false

    var body: some View {
        ZStack {
            preview
            scrim
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
        .fullScreenCover(isPresented: $showingExplorer) {
            MeshExplorerView(snapshots: explorerSnapshots)
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
            // Snapshot the textured mesh state RIGHT NOW so the explorer
            // gets the latest geometry. The capture session keeps running
            // in the background so anchors emitted while exploring will
            // appear in the next snapshot if the user re-opens it.
            explorerSnapshots = texturedMesh.snapshotForExplorer()
            showingExplorer = true
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

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
