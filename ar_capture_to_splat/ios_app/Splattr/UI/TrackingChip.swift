//
//  TrackingChip.swift
//  Status pill in the centre-top of the live HUD. Driven by GuidanceState.
//

import SwiftUI

struct TrackingChip: View {
    let guidance: GuidanceState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.7), radius: 6)
            Text(guidance.label.uppercased())
                .font(Theme.Font.caption(11))
                .tracking(2.0)
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            Capsule().stroke(color.opacity(0.55), lineWidth: 0.8)
        )
        .shadow(color: color.opacity(0.45), radius: 14)
    }

    private var color: Color {
        switch guidance.level {
        case .normal:    return Theme.Color.success
        case .warn:      return Theme.Color.halo
        case .critical:  return Theme.Color.danger
        }
    }
}
