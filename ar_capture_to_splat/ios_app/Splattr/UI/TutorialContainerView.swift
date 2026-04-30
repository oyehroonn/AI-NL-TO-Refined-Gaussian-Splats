//
//  TutorialContainerView.swift
//  Swipeable tutorial paginator. Steps come from ModeCopy; the final
//  "page" is always ModeConfirmView, which produces the CapturePolicy.
//
//  The "Skip" GhostButton appears only after the user has completed this
//  mode's tutorial at least once (TutorialMemory.hasCompleted(mode)).
//

import SwiftUI

struct TutorialContainerView: View {
    let descriptor: SessionDescriptor
    let host: String
    let mode: CaptureMode

    @EnvironmentObject var router: Router
    @State private var page = 0
    @State private var hasSeen: Bool

    private let steps: [TutorialStep]

    init(descriptor: SessionDescriptor, host: String, mode: CaptureMode) {
        self.descriptor = descriptor
        self.host = host
        self.mode = mode
        self.steps = ModeCopy.steps(for: mode)
        _hasSeen = State(initialValue: TutorialMemory.hasCompleted(mode))
    }

    /// One slot per step + one slot for the confirm screen.
    private var totalPages: Int { steps.count + 1 }

    var body: some View {
        VStack(spacing: 18) {
            progressDots
                .padding(.top, 18)
            content
            bottomBar
                .padding(.bottom, 14)
        }
        .background(Color.clear)
    }

    // MARK: - pieces

    private var content: some View {
        TabView(selection: $page) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { (idx, step) in
                TutorialStepView(step: step,
                                 stepIndex: idx,
                                 stepCount: steps.count,
                                 mode: mode)
                    .tag(idx)
            }
            ModeConfirmView(mode: mode,
                            descriptor: descriptor,
                            host: host,
                            tutorialSkipped: false)
                .tag(steps.count)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalPages, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Theme.Color.halo : Theme.Color.hairlineHi)
                    .frame(width: i == page ? 22 : 6, height: 6)
                    .shadow(color: i == page ? Theme.Color.halo.opacity(0.7) : .clear, radius: 6)
                    .animation(.easeInOut(duration: 0.35), value: page)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            GhostButton(title: "Cancel") { router.reset() }
            if hasSeen && page < steps.count {
                GhostButton(title: "Skip") {
                    skip()
                }
            }
            if page < steps.count {
                AccentHaloButton("Next", systemImage: "arrow.right") {
                    advance()
                }
            }
        }
        .padding(.horizontal, Theme.Layout.screenPadding)
    }

    // MARK: - actions

    private func advance() {
        if page < steps.count {
            withAnimation(.easeInOut) { page += 1 }
        }
    }

    private func skip() {
        // Jump straight to ModeConfirmView, but keep tutorial_skipped=true
        // so the policy reflects the user's choice. The confirm view will
        // be re-mounted with this flag via skip-routing.
        router.replaceWithSkippedConfirm(descriptor: descriptor, host: host, mode: mode)
    }
}

// Convenience helper used by the bottom-bar Skip button and by JoinView when
// it routes a returning user past the tutorial.
extension Router {
    func replaceWithSkippedConfirm(descriptor: SessionDescriptor,
                                   host: String,
                                   mode: CaptureMode) {
        // Reuse the tutorial state but jump to confirm-only with skipped=true.
        // Implemented by introducing a dedicated screen below in Router.swift.
        self.proceedToTutorialSkipped(descriptor: descriptor, host: host, mode: mode)
    }
}
