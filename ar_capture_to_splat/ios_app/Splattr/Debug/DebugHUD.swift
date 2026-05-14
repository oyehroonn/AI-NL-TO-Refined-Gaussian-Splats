//
//  DebugHUD.swift
//  Splattr — Gold Tier Perfection (Phase A1, debug surface).
//
//  SwiftUI overlay shown on top of any screen when `DebugMode.isEnabled`.
//  Live counters answer the four questions every grayscale-atlas
//  investigation has needed:
//
//   * "Did the phone get hot during this run?"           → thermal pill
//   * "Did we run out of memory?"                        → free MB
//   * "How many candidate views did we accept?"          → CandidateMetrics
//   * "How many anchors got real per-anchor textures?"   → AnchorMetrics
//   * "Where in the bake are we right now?"              → BakePhase line
//
//  Every counter is plain `@Published` on a single `BakeMetrics` actor —
//  the bake / coordinator pushes updates, the HUD reads. No KVO, no
//  notification chains.
//
//  Visual style: ink-on-charcoal pill at top-trailing, intentionally
//  compact so it doesn't fight the existing CaptureView HUD. Tap the
//  pill to expand to a full detail card; tap again to collapse.
//

import SwiftUI

// MARK: - Shared metrics

/// Thread-safe (main-actor) container the bake and coordinator push into.
/// HUD subscribes via @ObservedObject.
@MainActor
final class BakeMetrics: ObservableObject {
    static let shared = BakeMetrics()

    @Published var phase: String = "idle"
    @Published var phaseProgress: Double = 0      // 0...1 within current phase

    @Published var candidateViewsAccepted: Int = 0
    @Published var anchorsObserved: Int = 0
    @Published var anchorsWithTexture: Int = 0

    @Published var lastSubChunkMs: Double = 0
    @Published var totalTriangles: Int = 0
    @Published var totalAtlases: Int = 0

    @Published var lastChosenSentinelFraction: Double = -1   // -1 = N/A
    @Published var lastAtlasGreyFraction: Double = -1

    private init() {}

    func reset() {
        phase = "idle"; phaseProgress = 0
        candidateViewsAccepted = 0
        anchorsObserved = 0; anchorsWithTexture = 0
        lastSubChunkMs = 0
        totalTriangles = 0; totalAtlases = 0
        lastChosenSentinelFraction = -1
        lastAtlasGreyFraction = -1
    }
}

// MARK: - HUD view

struct DebugHUD: View {

    @AppStorage(DebugModeStorageKey.enabled) private var debugOn: Bool = false
    @ObservedObject private var thermal = ThermalObserver.shared
    @ObservedObject private var metrics = BakeMetrics.shared
    @State private var expanded = false

    var body: some View {
        if debugOn {
            VStack(alignment: .trailing, spacing: 4) {
                pill
                if expanded { detailCard }
            }
            .padding(.top, 12).padding(.trailing, 12)
            .animation(.easeInOut(duration: 0.18), value: expanded)
        }
    }

    private var pill: some View {
        Button(action: { expanded.toggle() }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: thermal.state.swiftUIColor.r,
                                 green: thermal.state.swiftUIColor.g,
                                 blue: thermal.state.swiftUIColor.b))
                    .frame(width: 8, height: 8)
                Text("DBG")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                Text(metrics.phase.uppercased())
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.black.opacity(0.66), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("thermal", thermal.state.label)
            row("free MB", String(format: "%.0f", freeMemoryMB()))
            row("phase", "\(metrics.phase) " +
                "\(String(format: "%.0f%%", metrics.phaseProgress * 100))")
            row("cand. views", "\(metrics.candidateViewsAccepted)")
            row("anchors", "\(metrics.anchorsWithTexture) / " +
                "\(metrics.anchorsObserved)")
            if metrics.totalTriangles > 0 {
                row("triangles", "\(metrics.totalTriangles) in " +
                    "\(metrics.totalAtlases) atlas(es)")
                row("last sub", String(format: "%.1f ms", metrics.lastSubChunkMs))
            }
            if metrics.lastChosenSentinelFraction >= 0 {
                row("sentinel", String(format: "%.1f%%",
                                       metrics.lastChosenSentinelFraction * 100))
            }
            if metrics.lastAtlasGreyFraction >= 0 {
                row("atlas grey", String(format: "%.1f%%",
                                          metrics.lastAtlasGreyFraction * 100))
            }
            Divider().background(Color.white.opacity(0.18))
            Button {
                shareLog()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share Debug Log").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
        }
        .padding(10)
        .frame(maxWidth: 220, alignment: .leading)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.66))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    private func freeMemoryMB() -> Double {
        // os_proc_available_memory: bytes the process can still allocate
        // before iOS terminates it. The most actionable "low memory"
        // signal on iOS — better than Mach host_statistics.
        Double(os_proc_available_memory()) / (1024.0 * 1024.0)
    }

    private func shareLog() {
        DebugLog.shared.flush()
        let url = DebugLog.shared.logFileURL
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive })
                as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else {
            return
        }
        let av = UIActivityViewController(activityItems: [url],
                                           applicationActivities: nil)
        // iPad source-rect requirement.
        av.popoverPresentationController?.sourceView = root.view
        av.popoverPresentationController?.sourceRect = CGRect(
            x: root.view.bounds.midX,
            y: root.view.bounds.midY,
            width: 0, height: 0
        )
        av.popoverPresentationController?.permittedArrowDirections = []
        // Present from whichever view-controller is topmost so we don't
        // collide with an existing sheet (e.g. the explorer cover).
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(av, animated: true)
    }
}
