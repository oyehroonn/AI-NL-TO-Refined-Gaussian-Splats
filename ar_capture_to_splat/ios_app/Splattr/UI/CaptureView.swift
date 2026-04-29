//
//  CaptureView.swift
//  AR-Layer-0-iOS placeholder: AVCaptureSession-based grab of N stills,
//  with a luxury HUD that previews the real ARKit experience to come.
//  Once AR-Layer 2 lands, the body of this view replaces AVCapture with
//  ARSession; the HUD/composition stays the same.
//

import SwiftUI
import AVFoundation

struct CaptureView: View {
    let descriptor: SessionDescriptor
    let host: String
    @EnvironmentObject var router: Router

    @StateObject private var camera = CameraCapture()
    @State private var error: String?
    @State private var configured = false
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt = Date()
    @State private var ticker: Timer?

    private let targetFrames = 30

    var body: some View {
        ZStack {
            preview
            scrim
            hud
        }
        .ignoresSafeArea()
        .alert("Camera error",
               isPresented: .init(get: { error != nil },
                                  set: { if !$0 { error = nil } })) {
            Button("Back") { router.reset() }
        } message: {
            Text(error ?? "")
        }
        .onAppear { Task { await start() } }
        .onDisappear { stopTicker(); camera.stop() }
    }

    // MARK: pieces

    private var preview: some View {
        Group {
            if let layer = camera.previewLayer {
                CameraPreview(layer: layer)
            } else {
                Theme.Color.ink
            }
        }
        .ignoresSafeArea()
    }

    private var scrim: some View {
        ZStack {
            // top + bottom darkening for HUD legibility
            LinearGradient(colors: [.black.opacity(0.65), .clear],
                           startPoint: .top, endPoint: .center)
            LinearGradient(colors: [.clear, .black.opacity(0.85)],
                           startPoint: .center, endPoint: .bottom)
            // amber vignette
            RadialGradient(colors: [.clear, Theme.Color.halo.opacity(0.10)],
                           center: .center,
                           startRadius: 100, endRadius: 600)
                .blendMode(.plusLighter)
        }
    }

    private var hud: some View {
        VStack(spacing: 0) {
            // Top status bar
            HStack {
                MonoPill(label: "REC", value: timeString(elapsed))
                Spacer()
                MonoPill(label: "FRAMES",
                         value: "\(camera.capturedCount)/\(targetFrames)")
            }
            .padding(.horizontal, 18)
            .padding(.top, 60)

            Spacer()

            // Centre crosshair + tracking chip
            VStack(spacing: 10) {
                CrosshairReticle()
                Text(trackingLabel.uppercased())
                    .font(Theme.Font.caption(11))
                    .tracking(2.0)
                    .foregroundStyle(Theme.Color.halo)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
                    .overlay(Capsule().stroke(Theme.Color.halo.opacity(0.6), lineWidth: 0.8))
                    .shadow(color: Theme.Color.halo.opacity(0.5), radius: 12)
            }

            Spacer()

            // Bottom dock
            VStack(spacing: 16) {
                progressBlock
                HStack(spacing: 12) {
                    GhostButton(title: "Cancel") { router.reset() }
                    AccentHaloButton("Stop & Upload", systemImage: "checkmark.circle.fill") {
                        finishAndUpload()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 38)
        }
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
        guard targetFrames > 0 else { return 0 }
        return min(1.0, Double(camera.capturedCount) / Double(targetFrames))
    }

    private var trackingLabel: String {
        if camera.capturedCount == 0 { return "warming up" }
        if camera.capturedCount >= targetFrames { return "ready to upload" }
        return "tracking · move slowly"
    }

    // MARK: lifecycle

    @MainActor
    private func start() async {
        guard !configured else { return }
        do {
            try await camera.configure()
            configured = true
            startedAt = Date()
            startTicker()
            camera.startCapturing(targetCount: targetFrames, intervalSeconds: 0.6) { frames in
                Task { @MainActor in
                    stopTicker()
                    router.proceedToUpload(descriptor: descriptor, host: host, frames: frames)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finishAndUpload() {
        camera.stop()
        stopTicker()
        Task { @MainActor in
            // Wait briefly for any in-flight photo to land, then route.
            try? await Task.sleep(nanoseconds: 250_000_000)
            if camera.frames.isEmpty {
                router.reset()
            } else {
                router.proceedToUpload(descriptor: descriptor,
                                        host: host,
                                        frames: camera.frames)
            }
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - AVCaptureVideoPreviewLayer wrapper

private struct CameraPreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer = layer
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) { uiView.previewLayer = layer }
}

private final class PreviewUIView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let l = previewLayer {
                l.frame = bounds
                layer.addSublayer(l)
            }
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

// MARK: - Crosshair

private struct CrosshairReticle: View {
    @State private var rotate = false
    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Color.halo.opacity(0.85), lineWidth: 1.0)
                .frame(width: 92, height: 92)
                .shadow(color: Theme.Color.halo.opacity(0.6), radius: 10)
            Circle()
                .trim(from: 0.0, to: 0.18)
                .stroke(Theme.Color.halo, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 110, height: 110)
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(.linear(duration: 4.0).repeatForever(autoreverses: false), value: rotate)
            Rectangle().fill(Theme.Color.halo).frame(width: 1, height: 14)
            Rectangle().fill(Theme.Color.halo).frame(width: 14, height: 1)
        }
        .onAppear { rotate = true }
    }
}

