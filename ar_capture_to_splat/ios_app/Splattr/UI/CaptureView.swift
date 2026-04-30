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

    @State private var error: String?
    @State private var configured = false
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt = Date()
    @State private var ticker: Timer?
    @State private var sectorFractions: [Double] = Array(repeating: 0, count: 8)

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
                        router.proceedToUpload(descriptor: descriptor,
                                                host: host,
                                                policy: policy,
                                                frames: frames,
                                                device: device,
                                                summary: summary)
                    }
                }
            }
            Task { await start() }
        }
        .onDisappear {
            stopTicker()
            coordinator.stop()
        }
    }

    // MARK: pieces

    private var preview: some View {
        ARSCNViewContainer(session: coordinator.arSession)
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
            HStack {
                MonoPill(label: "REC", value: timeString(elapsed))
                Spacer()
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

    private var bottomDock: some View {
        VStack(spacing: 16) {
            progressBlock
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
