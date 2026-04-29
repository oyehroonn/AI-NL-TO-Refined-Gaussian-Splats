//
//  ErrorView.swift
//

import SwiftUI

struct ErrorView: View {
    let message: String
    @EnvironmentObject var router: Router

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.Color.danger.opacity(0.45), .clear],
                                          center: .center, startRadius: 0, endRadius: 140))
                    .frame(width: 260, height: 260)
                    .blur(radius: 6)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.Color.danger)
                    .shadow(color: Theme.Color.danger.opacity(0.6), radius: 18)
            }
            VStack(spacing: 6) {
                Text("CAN'T CONNECT")
                    .font(Theme.Font.caption(11)).tracking(2.0)
                    .foregroundStyle(Theme.Color.textDim)
                Text(message)
                    .multilineTextAlignment(.center)
                    .font(Theme.Font.body(15))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .frame(maxWidth: 320)
            }
            Spacer()
            AccentHaloButton("Try Again", systemImage: "arrow.clockwise") { router.reset() }
        }
        .padding(Theme.Layout.screenPadding)
    }
}
