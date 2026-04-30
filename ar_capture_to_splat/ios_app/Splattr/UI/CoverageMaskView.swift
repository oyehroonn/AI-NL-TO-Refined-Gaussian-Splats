//
//  CoverageMaskView.swift
//  Radial fog-clearing visualisation: 8 yaw sectors arranged as wedges
//  around a center disc. Each sector contains 9 sub-cells (3 distance
//  rings × 3 pitch slices) — but for legibility the HUD aggregates per
//  sector, brightening as cells are filled.
//

import SwiftUI

struct CoverageMaskView: View {
    /// 0…1 — drives the global "fog clear" opacity.
    let coverageFraction: Double
    /// 0…7 yaw-sector visit counts, normalised to 0…1.
    let sectorVisitFractions: [Double]

    @State private var pulse = false

    private static let sectorCount = 8

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // 1. Soft-fog disc — fades as coverage rises.
                Circle()
                    .fill(RadialGradient(
                        colors: [
                            Theme.Color.ink.opacity(max(0.05, 0.55 - coverageFraction * 0.5)),
                            Theme.Color.ink.opacity(max(0.0, 0.30 - coverageFraction * 0.3)),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.5
                    ))
                    .frame(width: size, height: size)
                    .blur(radius: 6)

                // 2. Sector wedges — covered ones glow amber, uncovered stay dark
                ForEach(0..<Self.sectorCount, id: \.self) { i in
                    SectorWedge(
                        index: i,
                        sectorCount: Self.sectorCount,
                        intensity: i < sectorVisitFractions.count ? sectorVisitFractions[i] : 0
                    )
                    .frame(width: size, height: size)
                }

                // 3. Outer hairline ring with compass ticks
                ZStack {
                    Circle()
                        .stroke(Theme.Color.hairline, lineWidth: 0.8)
                        .frame(width: size, height: size)
                    ForEach(0..<Self.sectorCount, id: \.self) { i in
                        let angle = Angle(degrees: Double(i) * 360.0 / Double(Self.sectorCount))
                        Rectangle()
                            .fill(Theme.Color.hairlineHi)
                            .frame(width: 1, height: 8)
                            .offset(y: -size * 0.5 + 4)
                            .rotationEffect(angle)
                    }
                }

                // 4. Centre puck with %
                ZStack {
                    Circle()
                        .fill(Theme.Color.inkRaised.opacity(0.7))
                        .frame(width: 64, height: 64)
                    Circle()
                        .stroke(Theme.Color.halo.opacity(pulse ? 0.85 : 0.5), lineWidth: 1)
                        .frame(width: 64, height: 64)
                        .shadow(color: Theme.Color.halo.opacity(0.6), radius: 10)
                    Text("\(Int(coverageFraction * 100))%")
                        .font(Theme.Font.mono(13))
                        .foregroundStyle(Theme.Color.textPrimary)
                }
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct SectorWedge: View {
    let index: Int
    let sectorCount: Int
    let intensity: Double      // 0…1

    var body: some View {
        WedgeShape(index: index, sectorCount: sectorCount)
            .fill(LinearGradient(
                colors: [
                    Theme.Color.halo.opacity(0.25 + 0.55 * intensity),
                    Theme.Color.halo.opacity(0.05 + 0.20 * intensity)
                ],
                startPoint: .center,
                endPoint: .top
            ))
            .blur(radius: intensity > 0.6 ? 0.5 : 1.5)
            .opacity(0.10 + 0.55 * intensity)
            .blendMode(.plusLighter)
    }
}

private struct WedgeShape: Shape {
    let index: Int
    let sectorCount: Int

    func path(in r: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2
        let sectorWidth = 360.0 / Double(sectorCount)
        let mid = Double(index) * sectorWidth        // relative to "up"
        let half = sectorWidth / 2.0
        // Convert from "yaw 0 = front" to SwiftUI's angle frame
        // (0° = right, 90° = down). We use 0° = up for the HUD.
        let startSwift = mid - half - 90.0
        let endSwift = mid + half - 90.0
        p.move(to: center)
        p.addArc(center: center,
                 radius: radius * 0.85,
                 startAngle: .degrees(startSwift),
                 endAngle: .degrees(endSwift),
                 clockwise: false)
        p.closeSubpath()
        return p
    }
}
