//
//  Backgrounds.swift
//  Animated radial halo that sits behind every screen. Matches the
//  warm-amber glow around the astronaut helmet reference.
//

import SwiftUI

struct AnimatedHaloBackground: View {
    @State private var phase: CGFloat = 0
    @State private var pulseUp = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Warm primary halo
                RadialGradient(
                    colors: [
                        Theme.Color.halo.opacity(pulseUp ? 0.55 : 0.40),
                        Theme.Color.haloDeep.opacity(0.18),
                        .clear
                    ],
                    center: UnitPoint(x: 0.5, y: 0.18),
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.85
                )
                .blendMode(.plusLighter)
                .blur(radius: 40)
                // Cool secondary halo, anchored bottom-right
                RadialGradient(
                    colors: [
                        Theme.Color.electric.opacity(0.18),
                        Theme.Color.electric.opacity(0.06),
                        .clear
                    ],
                    center: UnitPoint(x: 0.95, y: 0.95),
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.80
                )
                .blendMode(.plusLighter)
                .blur(radius: 60)
                // Subtle grain
                NoiseLayer().opacity(0.05)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true)) {
                    pulseUp = true
                }
                withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
    }
}

/// Cheap shader-free noise via tiled symbol set; gives surfaces a non-flat feel.
private struct NoiseLayer: View {
    var body: some View {
        Canvas { ctx, size in
            for _ in 0..<400 {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let r = CGFloat.random(in: 0.4...1.4)
                let alpha = CGFloat.random(in: 0.05...0.18)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                    with: .color(.white.opacity(alpha))
                )
            }
        }
        .allowsHitTesting(false)
    }
}
