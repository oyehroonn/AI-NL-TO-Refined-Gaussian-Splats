//
//  TutorialStepView.swift
//  One swipeable page of the tutorial. Animated diagram on top, headline +
//  body in a glass card below, plus a small mode-tinted symbol badge.
//

import SwiftUI

struct TutorialStepView: View {
    let step: TutorialStep
    let stepIndex: Int
    let stepCount: Int
    let mode: CaptureMode

    @State private var appear = false

    var body: some View {
        VStack(spacing: 22) {
            badgeBar
            diagram
            copyCard
            Spacer(minLength: 0)
        }
        .padding(Theme.Layout.screenPadding)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 14)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appear = true }
        }
    }

    private var badgeBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: mode.badgeSymbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Color.halo)
                Text(mode.scanModeID.uppercased())
                    .font(Theme.Font.caption(10)).tracking(1.8)
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.Color.inkRaised.opacity(0.7)))
            .overlay(Capsule().stroke(Theme.Color.hairline, lineWidth: 0.8))
            Spacer()
            Text("\(stepIndex + 1) / \(stepCount)")
                .font(Theme.Font.mono(11))
                .foregroundStyle(Theme.Color.textDim)
        }
    }

    private var diagram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Layout.cardCornerRadius, style: .continuous)
                .fill(Theme.Color.inkSurface.opacity(0.55))
            RoundedRectangle(cornerRadius: Theme.Layout.cardCornerRadius, style: .continuous)
                .stroke(Theme.Color.hairline, lineWidth: 0.8)
            ModeDiagram(id: step.diagramID)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
    }

    private var copyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: step.symbol)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.Color.halo)
                        .shadow(color: Theme.Color.halo.opacity(0.7), radius: 6)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.Color.inkRaised.opacity(0.7)))
                        .overlay(Circle().stroke(Theme.Color.hairlineHi, lineWidth: 0.8))
                    Text(step.headline)
                        .font(Theme.Font.title(22))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(2).minimumScaleFactor(0.85)
                }
                Text(step.body)
                    .font(Theme.Font.body(15))
                    .foregroundStyle(Theme.Color.textMuted)
                    .lineSpacing(2)
            }
        }
    }
}
