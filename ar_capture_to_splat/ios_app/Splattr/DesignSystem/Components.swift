//
//  Components.swift
//  Reusable building blocks. Premium glass cards, accent buttons, technical
//  pill labels, animated progress rings.
//

import SwiftUI

// MARK: - Glass card

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var padding: CGFloat = Theme.Layout.cardPadding
    var cornerRadius: CGFloat = Theme.Layout.cardCornerRadius

    var body: some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.Color.inkSurface.opacity(0.45))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [
                            Theme.Color.hairlineHi,
                            Theme.Color.hairline
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8
                    )
            )
    }
}

// MARK: - Primary accent button

struct AccentHaloButton: View {
    let title: String
    let systemImage: String?
    var loading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    init(_ title: String,
         systemImage: String? = nil,
         loading: Bool = false,
         disabled: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.loading = loading
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if loading {
                    ProgressView().tint(.black)
                } else if let img = systemImage {
                    Image(systemName: img).font(.system(size: 16, weight: .bold))
                }
                Text(title.uppercased())
                    .font(.system(size: 14, weight: .heavy))
                    .tracking(2.0)
            }
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                ZStack {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.white, Theme.Color.halo.opacity(0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                    Capsule()
                        .stroke(Theme.Color.halo.opacity(0.85), lineWidth: 1.0)
                        .blur(radius: 0.5)
                }
            )
            .shadow(color: Theme.Color.halo.opacity(0.55), radius: 24, x: 0, y: 6)
            .opacity(disabled ? 0.5 : 1.0)
        }
        .disabled(disabled || loading)
        .buttonStyle(.plain)
    }
}

// MARK: - Ghost button (secondary)

struct GhostButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .bold))
                .tracking(2.0)
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .overlay(Capsule().stroke(Theme.Color.hairlineHi, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Technical pill label (mono)

struct MonoPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(Theme.Font.caption(10))
                .tracking(1.6)
                .foregroundStyle(Theme.Color.textDim)
            Text(value)
                .font(Theme.Font.mono(12))
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(Theme.Color.inkRaised.opacity(0.7))
        )
        .overlay(Capsule().stroke(Theme.Color.hairline, lineWidth: 0.8))
    }
}

// MARK: - Section heading (oversized display)

struct DisplayHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.Font.display(64))
                .tracking(-1.5)
                .lineSpacing(-6)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            if let sub = subtitle {
                Text(sub)
                    .font(Theme.Font.body(15))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
    }
}

// MARK: - Animated progress ring

struct NeonProgressRing: View {
    /// 0.0–1.0
    var progress: Double
    var lineWidth: CGFloat = 6
    var size: CGFloat = 120

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Color.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(
                    AngularGradient(colors: [Theme.Color.halo, Theme.Color.electric, Theme.Color.halo],
                                    center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.Color.halo.opacity(0.7), radius: 8)
                .animation(.easeInOut(duration: 0.4), value: progress)
            Text("\(Int(progress * 100))%")
                .font(Theme.Font.mono(14))
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Indeterminate scanning bar

struct ScanningBar: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Color.hairline)
                Capsule()
                    .fill(LinearGradient(
                        colors: [.clear, Theme.Color.halo, .clear],
                        startPoint: .leading,
                        endPoint: .trailing))
                    .frame(width: geo.size.width * 0.42)
                    .offset(x: phase * (geo.size.width - geo.size.width * 0.42))
                    .shadow(color: Theme.Color.halo.opacity(0.6), radius: 10)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
        }
        .frame(height: 3)
    }
}
