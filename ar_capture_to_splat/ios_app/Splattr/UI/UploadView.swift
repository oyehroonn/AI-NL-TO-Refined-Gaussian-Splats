//
//  UploadView.swift
//  Streaming progress + result screen for POST /upload.
//

import SwiftUI

struct UploadView: View {
    let descriptor: SessionDescriptor
    let host: String
    let policy: CapturePolicy
    let frames: [CapturedFrame]
    let device: Manifest.Device
    let summary: Manifest.Summary
    let worldMapURL: URL?
    let meshURL: URL?
    let rejectedFramesURL: URL?
    @EnvironmentObject var router: Router

    @State private var progress: Double = 0.0
    @State private var statusLine: String = "Preparing capture package…"
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            NeonProgressRing(progress: progress, lineWidth: 8, size: 168)
            VStack(spacing: 6) {
                Text(statusLine)
                    .font(Theme.Font.body(15))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("\(frames.count) frames · \(host)")
                    .font(Theme.Font.mono(11))
                    .foregroundStyle(Theme.Color.textDim)
            }
            Spacer()
            if let f = failure {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("UPLOAD FAILED")
                            .font(Theme.Font.caption(11)).tracking(2.0)
                            .foregroundStyle(Theme.Color.danger)
                        Text(f)
                            .font(Theme.Font.body(14))
                            .foregroundStyle(Theme.Color.textPrimary)
                    }
                }
                AccentHaloButton("Try Again", systemImage: "arrow.clockwise") {
                    failure = nil; progress = 0; Task { await upload() }
                }
                GhostButton(title: "Back") { router.reset() }
            } else {
                ScanningBar()
            }
        }
        .padding(Theme.Layout.screenPadding)
        .onAppear { Task { await upload() } }
    }

    @MainActor
    private func upload() async {
        statusLine = "Building manifest…"
        do {
            let resp = try await ManifestUploader(host: host).upload(
                descriptor: descriptor,
                sceneType: policy.scene_type,
                policy: policy,
                frames: frames,
                device: device,
                summary: summary,
                worldMapURL: worldMapURL,
                meshURL: meshURL,
                rejectedFramesURL: rejectedFramesURL
            ) { p in
                Task { @MainActor in
                    progress = p
                    statusLine = p < 0.95 ? "Uploading frames…" : "Finalising…"
                }
            }
            statusLine = "Done."
            try? await Task.sleep(nanoseconds: 350_000_000)
            router.finished(summary: resp)
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct DoneView: View {
    let summary: UploadSummary
    @EnvironmentObject var router: Router

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.Color.success.opacity(0.5), .clear],
                                          center: .center, startRadius: 0, endRadius: 140))
                    .frame(width: 280, height: 280)
                    .blur(radius: 8)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 88, weight: .light))
                    .foregroundStyle(Theme.Color.success)
                    .shadow(color: Theme.Color.success.opacity(0.6), radius: 18)
            }
            VStack(spacing: 6) {
                Text("CAPTURE DELIVERED")
                    .font(Theme.Font.caption(11)).tracking(2.0)
                    .foregroundStyle(Theme.Color.textDim)
                Text(summary.runID)
                    .font(Theme.Font.title(26))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("\(summary.framesReceived) frames received · depth \(summary.depthReceived)")
                    .font(Theme.Font.mono(12))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            Spacer()
            AccentHaloButton("Done", systemImage: "checkmark") { router.reset() }
        }
        .padding(Theme.Layout.screenPadding)
    }
}
