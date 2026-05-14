//
//  JoinView.swift
//  Shown the moment a `claudesplat://` link is opened. Confirms the
//  laptop session, lets the user pick a scene type if they want to
//  override, then hands off to CaptureView.
//

import SwiftUI

struct JoinView: View {
    let descriptor: SessionDescriptor
    let host: String
    @EnvironmentObject var router: Router

    @State private var sceneType: SceneType
    @State private var tipsLoading = true
    @State private var tips: [String] = []
    @State private var appearAnim = false
    @State private var cadence: CaptureCadence = CaptureSettings.cadence()
    @State private var tier: Tier = CaptureSettings.tier()
    @AppStorage(DebugModeStorageKey.enabled) private var debugOn: Bool = false
    @State private var syntheticRunning = false
    @State private var syntheticResult: String? = nil

    init(descriptor: SessionDescriptor, host: String) {
        self.descriptor = descriptor
        self.host = host
        let initial = SceneType(rawValue: descriptor.displaySceneType) ?? .room
        _sceneType = State(initialValue: initial)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                header
                pillsRow
                sceneSelector
                cadenceCard
                tierCard
                tipsCard
                if debugOn { debugCard }
                Spacer(minLength: 12)
            }
            .padding(Theme.Layout.screenPadding)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                AccentHaloButton("Continue", systemImage: "arrow.right") {
                    let mode = CaptureModeCatalog.mode(for: sceneType)
                    router.startTutorial(descriptor: descriptor, host: host, mode: mode)
                }
                GhostButton(title: "Cancel") { router.reset() }
            }
            .padding(.horizontal, Theme.Layout.screenPadding)
            .padding(.bottom, 14)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appearAnim = true }
            Task { await loadTips() }
        }
        .onChange(of: sceneType) { _, _ in Task { await loadTips() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("CONNECTED")
                    .font(Theme.Font.caption(11)).tracking(2.0)
                    .foregroundStyle(Theme.Color.success)
                    // Hidden 1.2s long-press toggles the on-phone debug
                    // surface (HUD, file log, artifact dumper). Intentionally
                    // undiscoverable to avoid clutter for non-dev users.
                    .onLongPressGesture(minimumDuration: 1.2) {
                        debugOn.toggle()
                        DebugLog.shared.info(
                            "debugmode",
                            "toggled via JoinView pill → \(debugOn ? "ON" : "OFF")"
                        )
                    }
                Circle().fill(Theme.Color.success).frame(width: 6, height: 6)
                    .shadow(color: Theme.Color.success.opacity(0.8), radius: 6)
                if debugOn {
                    Text("DEBUG")
                        .font(Theme.Font.caption(10)).tracking(1.6)
                        .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.30))
                }
                Spacer()
            }
            DisplayHeading(title: descriptor.displayVideoName,
                           subtitle: "Capture session ready on the laptop. Hold the phone steady, walk slowly.")
                .opacity(appearAnim ? 1 : 0)
                .offset(y: appearAnim ? 0 : 12)
        }
    }

    private var pillsRow: some View {
        HStack(spacing: 8) {
            MonoPill(label: "session", value: descriptor.session_id)
            MonoPill(label: "run", value: descriptor.run_id)
            Spacer()
        }
    }

    private var sceneSelector: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("SCENE TYPE")
                    .font(Theme.Font.caption(11))
                    .tracking(2.0)
                    .foregroundStyle(Theme.Color.textDim)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(SceneType.allCases) { type in
                            SceneChip(type: type, selected: type == sceneType) {
                                sceneType = type
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var cadenceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("CAPTURE CADENCE")
                        .font(Theme.Font.caption(11)).tracking(2.0)
                        .foregroundStyle(Theme.Color.textDim)
                    Spacer()
                    Text("ARKit frame rate")
                        .font(Theme.Font.mono(11))
                        .foregroundStyle(Theme.Color.textDim)
                }
                HStack(spacing: 10) {
                    ForEach(CaptureCadence.allCases) { c in
                        Button {
                            cadence = c
                            CaptureSettings.setCadence(c)
                        } label: {
                            Text(c.label.uppercased())
                                .font(.system(size: 12, weight: .heavy))
                                .tracking(1.4)
                                .foregroundStyle(c == cadence ? Color.black : Theme.Color.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule().fill(
                                        c == cadence
                                          ? AnyShapeStyle(LinearGradient(colors: [.white, Theme.Color.halo],
                                                                          startPoint: .topLeading,
                                                                          endPoint: .bottomTrailing))
                                          : AnyShapeStyle(Theme.Color.inkRaised.opacity(0.7))
                                    )
                                )
                                .overlay(
                                    Capsule().stroke(c == cadence ? Theme.Color.halo : Theme.Color.hairline,
                                                      lineWidth: c == cadence ? 1.0 : 0.8)
                                )
                                .shadow(color: c == cadence ? Theme.Color.halo.opacity(0.45) : .clear, radius: 12)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                Text("60 Hz: smoother HUD + faster coverage. 30 Hz: longer battery, fewer frames per second.")
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
    }

    private var tierCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("QUALITY")
                        .font(Theme.Font.caption(11)).tracking(2.0)
                        .foregroundStyle(Theme.Color.textDim)
                    Spacer()
                    Text("preview tier")
                        .font(Theme.Font.mono(11))
                        .foregroundStyle(Theme.Color.textDim)
                }
                VStack(spacing: 8) {
                    ForEach(Tier.allCases) { t in
                        TierRow(
                            tier: t,
                            selected: t == tier,
                            disabled: !t.isAvailable
                        ) {
                            guard t.isAvailable else { return }
                            tier = t
                            CaptureSettings.setTier(t)
                        }
                    }
                }
                Text(tier.blurb)
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
    }

    private var tipsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("HOW TO MOVE")
                        .font(Theme.Font.caption(11)).tracking(2.0)
                        .foregroundStyle(Theme.Color.textDim)
                    Spacer()
                    if tipsLoading {
                        ProgressView().tint(Theme.Color.halo).scaleEffect(0.7)
                    }
                }
                ForEach(tips.prefix(6), id: \.self) { tip in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(Theme.Color.halo)
                            .frame(width: 6, height: 6)
                            .padding(.top, 8)
                            .shadow(color: Theme.Color.halo.opacity(0.6), radius: 4)
                        Text(tip)
                            .font(Theme.Font.body(15))
                            .foregroundStyle(Theme.Color.textPrimary)
                    }
                }
                if tips.isEmpty && !tipsLoading {
                    Text("Move slowly. Walk sideways too. Cover near and far views.")
                        .font(Theme.Font.body(15))
                        .foregroundStyle(Theme.Color.textPrimary)
                }
            }
        }
    }

    // MARK: - Debug card
    //
    // Only visible when DebugMode is enabled (long-press the CONNECTED
    // pill to toggle). Exposes the two debug actions a developer needs
    // before going into the field:
    //   - Run Synthetic Bake Test → fires MeshAtlasBaker on a known-good
    //     3-tri + 1-checkerboard scene; dumps the atlas as PNG.
    //   - Share Debug Log → AirDrops the current session's
    //     `tmp/splattr_debug_<stamp>.log` off-device.
    private var debugCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("DEBUG TOOLS")
                        .font(Theme.Font.caption(11)).tracking(2.0)
                        .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.30))
                    Spacer()
                    Text("v1")
                        .font(Theme.Font.mono(10))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                Text("Long-press the CONNECTED pill to hide.")
                    .font(Theme.Font.body(12))
                    .foregroundStyle(Theme.Color.textMuted)

                Button {
                    runSyntheticBake()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: syntheticRunning
                              ? "hourglass" : "wand.and.stars")
                        Text(syntheticRunning
                             ? "Running synthetic bake…"
                             : "Run Synthetic Bake Test")
                            .font(Theme.Font.body(14).weight(.semibold))
                    }
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(syntheticRunning)
                .foregroundStyle(Theme.Color.textPrimary)

                Button {
                    DebugLog.shared.flush()
                    shareDebugLog()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share Debug Log")
                            .font(Theme.Font.body(14).weight(.semibold))
                    }
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .foregroundStyle(Theme.Color.textPrimary)

                if let result = syntheticResult {
                    Text(result)
                        .font(Theme.Font.mono(10))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func runSyntheticBake() {
        syntheticRunning = true
        syntheticResult = nil
        SyntheticBakeScene.run { result in
            syntheticRunning = false
            switch result {
            case .success(let summary): syntheticResult = summary
            case .failure(let err):
                syntheticResult = "FAILED: \(err)"
                DebugLog.shared.error("synthetic", "\(err)")
            }
        }
    }

    private func shareDebugLog() {
        let url = DebugLog.shared.logFileURL
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive })
                as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else {
            return
        }
        let av = UIActivityViewController(activityItems: [url],
                                           applicationActivities: nil)
        av.popoverPresentationController?.sourceView = root.view
        av.popoverPresentationController?.sourceRect = CGRect(
            x: root.view.bounds.midX,
            y: root.view.bounds.midY,
            width: 0, height: 0
        )
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(av, animated: true)
    }

    @MainActor
    private func loadTips() async {
        tipsLoading = true
        defer { tipsLoading = false }
        do {
            let cfg = try await SessionClient(host: host).fetchTutorialConfig(sceneType: sceneType.rawValue)
            self.tips = cfg.tips
        } catch {
            self.tips = []
        }
    }
}

private struct SceneChip: View {
    let type: SceneType
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: type.systemImage).font(.system(size: 13, weight: .semibold))
                Text(type.label.uppercased())
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(1.4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(selected ? Color.black : Theme.Color.textPrimary)
            .background(
                Capsule()
                    .fill(selected
                          ? AnyShapeStyle(LinearGradient(colors: [.white, Theme.Color.halo],
                                                         startPoint: .topLeading,
                                                         endPoint: .bottomTrailing))
                          : AnyShapeStyle(Theme.Color.inkRaised.opacity(0.7)))
            )
            .overlay(
                Capsule().stroke(selected ? Theme.Color.halo : Theme.Color.hairline,
                                 lineWidth: selected ? 1.0 : 0.8)
            )
            .shadow(color: selected ? Theme.Color.halo.opacity(0.45) : .clear, radius: 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tier row

/// One selectable row in the tier card. Selected → halo-fill,
/// unavailable → dimmed with a "soon" badge.
private struct TierRow: View {
    let tier: Tier
    let selected: Bool
    let disabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(tier.displayName)
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.6)
                    .foregroundStyle(textColor)
                Spacer()
                Text(disabled ? "SOON" : tier.pill)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(pillTextColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(pillBackground)
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(rowBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(rowBorder, lineWidth: selected ? 1.2 : 0.8)
            )
            .shadow(color: selected ? Theme.Color.halo.opacity(0.35) : .clear,
                    radius: 14)
            .opacity(disabled ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var textColor: Color {
        selected ? Color.black : Theme.Color.textPrimary
    }

    private var rowBackground: AnyShapeStyle {
        if selected {
            return AnyShapeStyle(LinearGradient(
                colors: [.white, Theme.Color.halo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(Theme.Color.inkRaised.opacity(0.55))
    }

    private var rowBorder: Color {
        selected ? Theme.Color.halo : Theme.Color.hairline
    }

    private var pillTextColor: Color {
        if disabled { return Theme.Color.textMuted }
        return selected ? Color.black : Theme.Color.halo
    }

    private var pillBackground: AnyShapeStyle {
        if disabled { return AnyShapeStyle(Theme.Color.inkRaised.opacity(0.4)) }
        return AnyShapeStyle(
            (selected ? Color.black : Theme.Color.halo).opacity(selected ? 0.10 : 0.18)
        )
    }
}
