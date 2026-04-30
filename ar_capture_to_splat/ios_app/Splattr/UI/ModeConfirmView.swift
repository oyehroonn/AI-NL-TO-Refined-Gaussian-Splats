//
//  ModeConfirmView.swift
//  Final tutorial page (or the standalone screen when the user skipped).
//  Builds the CapturePolicy and routes to CaptureView.
//

import SwiftUI

struct ModeConfirmView: View {
    let mode: CaptureMode
    let descriptor: SessionDescriptor
    let host: String
    let tutorialSkipped: Bool

    @EnvironmentObject var router: Router

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header
                summaryGrid
                tipsCard
                Spacer(minLength: 16)
            }
            .padding(Theme.Layout.screenPadding)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                AccentHaloButton("Begin Capture", systemImage: "viewfinder.circle") {
                    confirm()
                }
                GhostButton(title: "Pick a different scene") {
                    router.reset()  // sends user back to splash → join
                }
            }
            .padding(.horizontal, Theme.Layout.screenPadding)
            .padding(.bottom, 14)
        }
    }

    // MARK: pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: mode.badgeSymbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Color.halo)
                Text("READY TO SCAN")
                    .font(Theme.Font.caption(11)).tracking(2.0)
                    .foregroundStyle(Theme.Color.success)
                Circle().fill(Theme.Color.success).frame(width: 6, height: 6)
                    .shadow(color: Theme.Color.success.opacity(0.7), radius: 6)
                Spacer()
            }
            DisplayHeading(
                title: mode.displayHeadline,
                subtitle: tutorialSkipped
                    ? "Skipped the walkthrough. Move slowly and keep the phone steady."
                    : "Here's how this scan will run on the laptop side."
            )
        }
    }

    private var summaryGrid: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("CAPTURE POLICY")
                    .font(Theme.Font.caption(11)).tracking(2.0)
                    .foregroundStyle(Theme.Color.textDim)
                FlowLayout(spacing: 8) {
                    MonoPill(label: "mode", value: mode.scanModeID)
                    MonoPill(label: "frames", value: "\(mode.frameBudget.target)")
                    MonoPill(label: "near", value: String(format: "%.1f m", mode.distanceBand.near))
                    MonoPill(label: "far", value: String(format: "%.1f m", mode.distanceBand.far))
                    MonoPill(label: "speed", value: String(format: "≤%.2f m/s", mode.movement.max_speed_mps))
                    MonoPill(label: "loop", value: mode.coverageTargets.loop_closure_required ? "yes" : "no")
                }
            }
        }
    }

    private var tipsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("REMEMBER")
                    .font(Theme.Font.caption(11)).tracking(2.0)
                    .foregroundStyle(Theme.Color.textDim)
                bullet("Move slowly — walking pace, not running pace.")
                bullet("Cover near and far in the same scan.")
                bullet("Stop when coverage is full, not when the timer is long.")
            }
        }
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(Theme.Color.halo).frame(width: 6, height: 6)
                .padding(.top, 8)
                .shadow(color: Theme.Color.halo.opacity(0.6), radius: 4)
            Text(text).font(Theme.Font.body(15))
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }

    // MARK: action

    private func confirm() {
        TutorialMemory.markCompleted(mode)
        let policy = CapturePolicy.make(
            from: mode,
            tutorialRun: !tutorialSkipped,
            tutorialSkipped: tutorialSkipped
        )
        router.proceedToCapture(descriptor: descriptor, host: host, policy: policy)
    }
}

// MARK: - tiny FlowLayout for MonoPill grid

/// Wraps MonoPills onto multiple rows. SwiftUI's HStack doesn't wrap; this is
/// a minimal implementation, just enough for ~6 pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var x: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth {
                totalHeight += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.minX + maxWidth {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
