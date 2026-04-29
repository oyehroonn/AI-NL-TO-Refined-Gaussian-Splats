//
//  SplashView.swift
//  First screen the user ever sees. Three states:
//    1. before any QR has been scanned: instructional copy + halo
//    2. while fetching /session: animated scanning
//    3. failure: drops into ErrorView via Router
//

import SwiftUI

struct SplashView: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            haloMark
                .scaleEffect(pulse ? 1.08 : 0.96)
                .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: pulse)
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 12) {
                MonoPill(label: "v1", value: "splattr.capture")
                Text("SCAN. CAPTURE.\nSPLAT.")
                    .font(Theme.Font.display(48))
                    .tracking(-1.0)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(3)
                Text("Open the laptop pipeline, choose record, and scan the QR code on its screen with your phone's camera. This app launches automatically.")
                    .font(Theme.Font.body(15))
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Layout.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Layout.cardCornerRadius, style: .continuous)
                    .fill(Theme.Color.inkSurface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.cardCornerRadius, style: .continuous)
                    .stroke(Theme.Color.hairline, lineWidth: 0.8)
            )
            ScanningBar()
                .padding(.horizontal, 4)
            Spacer(minLength: 0)
        }
        .padding(Theme.Layout.screenPadding)
        .onAppear { pulse = true }
    }

    private var haloMark: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.Color.halo.opacity(0.85),
                            Theme.Color.halo.opacity(0.18),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)
                .blur(radius: 4)
            Circle()
                .stroke(Theme.Color.halo.opacity(0.55), lineWidth: 1.0)
                .frame(width: 132, height: 132)
                .shadow(color: Theme.Color.halo.opacity(0.7), radius: 14)
            Circle()
                .stroke(Theme.Color.halo.opacity(0.85), lineWidth: 0.8)
                .frame(width: 84, height: 84)
            Image(systemName: "viewfinder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }
}
