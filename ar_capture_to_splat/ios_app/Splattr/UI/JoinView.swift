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
                tipsCard
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
                Circle().fill(Theme.Color.success).frame(width: 6, height: 6)
                    .shadow(color: Theme.Color.success.opacity(0.8), radius: 6)
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
