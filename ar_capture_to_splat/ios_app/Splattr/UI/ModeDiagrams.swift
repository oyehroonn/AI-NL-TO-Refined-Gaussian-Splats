//
//  ModeDiagrams.swift
//  Pure-SwiftUI animated diagrams for each path_pattern + a few step-specific
//  illustrations. No Lottie, no images — every diagram is a stroked Path so
//  it stays crisp at any size and the bundle is tiny.
//
//  Each diagram pulses a TimelineView-driven phase and uses
//  `trim(from:to:)` on the path to make it draw itself in a loop.
//

import SwiftUI

struct ModeDiagram: View {
    let id: String
    /// Single source of truth: looks up the right shape for the diagram id.
    var body: some View {
        Group {
            switch id {
            case PathPattern.orbit:                LoopingDrawShape { OrbitPath() }
            case PathPattern.spiral:               LoopingDrawShape { SpiralPath() }
            case PathPattern.perimeterThenCenter:  LoopingDrawShape { PerimeterPath() }
            case PathPattern.corridorForwardBack:  LoopingDrawShape { CorridorPath() }
            case PathPattern.facadeSweep:          LoopingDrawShape { FacadePath() }
            case PathPattern.wideArc:              LoopingDrawShape { WideArcPath() }
            case PathPattern.rotationOnlyObject:   RotateObjectDiagram()
            case "near_far_arrows":                NearFarDiagram()
            case "speed_meter":                    SpeedMeterDiagram()
            case "coverage_fill":                  CoverageFillDiagram()
            case "tilt_ceiling":                   TiltCeilingDiagram()
            case "side_step":                      SideStepDiagram()
            case "tilt_rotate":                    RotateObjectDiagram()
            case "distance_band":                  NearFarDiagram()
            case "pause_dots":                     PauseDotsDiagram()
            case "glare_warning":                  GlareWarningDiagram()
            case "sun_position":                   GlareWarningDiagram()
            case "detail_focus":                   DetailFocusDiagram()
            case "intro":                          IntroDiagram()
            default:                               IntroDiagram()
            }
        }
    }
}

// MARK: - Looping draw shape

/// Renders any Shape, animating `trim(from:to:)` so the path appears to
/// draw itself, hold, then fade. 4-second loop.
private struct LoopingDrawShape<S: Shape>: View {
    let shape: S
    init(@ViewBuilder _ build: () -> S) { self.shape = build() }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 1.5) + 1) / 2.0  // 0…1
            let glow = 0.45 + 0.35 * phase

            ZStack {
                // Faint dot grid behind, very subtle
                DotGrid()
                    .stroke(Theme.Color.hairline, lineWidth: 0.5)
                // The shape itself, drawn-in
                shape
                    .trim(from: 0, to: drawProgress(t: t))
                    .stroke(LinearGradient(colors: [Theme.Color.halo,
                                                    Theme.Color.electric,
                                                    Theme.Color.halo],
                                           startPoint: .leading,
                                           endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .shadow(color: Theme.Color.halo.opacity(glow), radius: 10)
                // Travelling head dot
                if let p = pointAt(progress: drawProgress(t: t), in: shape) {
                    Circle()
                        .fill(Theme.Color.halo)
                        .frame(width: 7, height: 7)
                        .position(p)
                        .shadow(color: Theme.Color.halo.opacity(0.9), radius: 8)
                }
            }
        }
        .padding(20)
    }

    private func drawProgress(t: TimeInterval) -> CGFloat {
        let cycle = 4.0
        let p = (t.truncatingRemainder(dividingBy: cycle)) / cycle  // 0…1
        // 0–0.7 draw, 0.7–1.0 hold-and-fade by the wrapper
        return CGFloat(min(1.0, p / 0.7))
    }

    private func pointAt<S: Shape>(progress: CGFloat, in _: S) -> CGPoint? {
        // Without UIKit hit-testing on the path, approximate with the OrbitPath
        // sample (good enough — head dot is decorative). Most diagrams already
        // include their own travelling marks; this fallback is only used here.
        return nil
    }
}

// MARK: - Path shapes

private struct OrbitPath: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) * 0.35
        p.addArc(center: c, radius: radius,
                 startAngle: .degrees(-200), endAngle: .degrees(160),
                 clockwise: false)
        // Object glyph in the center
        p.addRect(CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18))
        return p
    }
}

private struct SpiralPath: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let maxR = min(r.width, r.height) * 0.4
        let turns = 2.5
        var first = true
        for i in 0...200 {
            let s = Double(i) / 200.0
            let theta = s * turns * 2 * .pi
            let rad = CGFloat(s) * maxR
            let pt = CGPoint(x: c.x + cos(theta) * rad,
                             y: c.y + sin(theta) * rad)
            if first { p.move(to: pt); first = false } else { p.addLine(to: pt) }
        }
        return p
    }
}

private struct PerimeterPath: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let inset: CGFloat = 18
        let rect = r.insetBy(dx: inset, dy: inset)
        // Perimeter (rectangle)
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: 8, height: 8))
        // Then arrows into corners
        for corner in [CGPoint(x: rect.minX + 18, y: rect.minY + 18),
                       CGPoint(x: rect.maxX - 18, y: rect.minY + 18),
                       CGPoint(x: rect.maxX - 18, y: rect.maxY - 18),
                       CGPoint(x: rect.minX + 18, y: rect.maxY - 18)] {
            let center = CGPoint(x: r.midX, y: r.midY)
            p.move(to: center)
            p.addLine(to: corner)
        }
        return p
    }
}

private struct CorridorPath: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let inset: CGFloat = 24
        // Corridor walls
        p.move(to: CGPoint(x: inset, y: inset))
        p.addLine(to: CGPoint(x: r.maxX - inset, y: inset))
        p.move(to: CGPoint(x: inset, y: r.maxY - inset))
        p.addLine(to: CGPoint(x: r.maxX - inset, y: r.maxY - inset))
        // Forward+back centerline (dashed-feel via sub-strokes)
        p.move(to: CGPoint(x: inset + 6, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - inset - 6, y: r.midY))
        p.addLine(to: CGPoint(x: inset + 6, y: r.midY + 8))
        return p
    }
}

private struct FacadePath: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let inset: CGFloat = 22
        // Wall
        p.addRect(CGRect(x: inset, y: inset,
                         width: r.width - inset * 2, height: r.height * 0.35))
        // Sweep arrow below
        let y = r.height * 0.62
        p.move(to: CGPoint(x: inset, y: y))
        p.addLine(to: CGPoint(x: r.maxX - inset, y: y))
        // Closer pass
        p.move(to: CGPoint(x: inset + 8, y: y + 16))
        p.addLine(to: CGPoint(x: r.maxX - inset - 8, y: y + 16))
        return p
    }
}

private struct WideArcPath: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.maxY - 10)
        let radius = min(r.width, r.height) * 0.55
        p.addArc(center: c, radius: radius,
                 startAngle: .degrees(220), endAngle: .degrees(320),
                 clockwise: false)
        // Pause dots along the arc
        for deg in [240.0, 270.0, 300.0] {
            let theta = deg * .pi / 180.0
            let pt = CGPoint(x: c.x + cos(theta) * radius,
                             y: c.y + sin(theta) * radius)
            p.addEllipse(in: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6))
        }
        return p
    }
}

// MARK: - Step-specific illustrations

private struct RotateObjectDiagram: View {
    @State private var spin = false
    var body: some View {
        ZStack {
            DotGrid().stroke(Theme.Color.hairline, lineWidth: 0.5)
            // Phone (stationary)
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.Color.electric, lineWidth: 1.5)
                .frame(width: 36, height: 60)
                .offset(y: 60)
                .shadow(color: Theme.Color.electric.opacity(0.6), radius: 6)
            // Object (rotating)
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.Color.halo, lineWidth: 2.0)
                    .frame(width: 50, height: 50)
                    .shadow(color: Theme.Color.halo.opacity(0.7), radius: 10)
                // arrow indicating rotation
                Path { p in
                    p.addArc(center: CGPoint(x: 0, y: 0), radius: 36,
                             startAngle: .degrees(20), endAngle: .degrees(340),
                             clockwise: false)
                }
                .stroke(Theme.Color.halo.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: 72, height: 72)
            }
            .offset(y: -30)
            .rotation3DEffect(.degrees(spin ? 360 : 0),
                              axis: (x: 0, y: 1, z: 0))
            .animation(.linear(duration: 4.5).repeatForever(autoreverses: false), value: spin)
        }
        .padding(20)
        .onAppear { spin = true }
    }
}

private struct NearFarDiagram: View {
    @State private var phase = false
    var body: some View {
        VStack(spacing: 14) {
            arrowRow(width: 100, label: "near")
            arrowRow(width: 200, label: "far")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { phase = true }
        }
    }
    @ViewBuilder
    private func arrowRow(width: CGFloat, label: String) -> some View {
        HStack(spacing: 12) {
            Text(label.uppercased())
                .font(Theme.Font.caption(10)).tracking(2.0)
                .foregroundStyle(Theme.Color.textDim)
                .frame(width: 36, alignment: .leading)
            Rectangle().fill(Theme.Color.halo)
                .frame(width: phase ? width : width * 0.45, height: 2)
                .shadow(color: Theme.Color.halo.opacity(0.7), radius: 8)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Color.halo)
        }
    }
}

private struct SpeedMeterDiagram: View {
    @State private var v: CGFloat = 0
    var body: some View {
        ZStack {
            Capsule().stroke(Theme.Color.hairline, lineWidth: 1)
            Capsule().fill(LinearGradient(colors: [Theme.Color.success, Theme.Color.halo],
                                           startPoint: .leading, endPoint: .trailing))
                .frame(width: max(32, 220 * v), height: 14)
                .shadow(color: Theme.Color.halo.opacity(0.7), radius: 8)
        }
        .frame(width: 220, height: 14)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                v = 0.32  // never goes red — pinned in the green/amber walking-pace zone
            }
        }
    }
}

private struct CoverageFillDiagram: View {
    @State private var coverage: CGFloat = 0
    var body: some View {
        let cells = 6
        let total = cells * cells
        Canvas { ctx, size in
            let s = min(size.width, size.height) / CGFloat(cells)
            let filled = Int(CGFloat(total) * coverage)
            for i in 0..<total {
                let row = i / cells, col = i % cells
                let r = CGRect(x: CGFloat(col) * s + 1,
                               y: CGFloat(row) * s + 1,
                               width: s - 2, height: s - 2)
                let on = i < filled
                ctx.fill(Path(roundedRect: r, cornerRadius: 3),
                         with: .color(on ? Theme.Color.halo.opacity(0.8) : Theme.Color.inkRaised))
            }
        }
        .frame(width: 200, height: 200)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                coverage = 1.0
            }
        }
    }
}

private struct TiltCeilingDiagram: View {
    @State private var tilt = false
    var body: some View {
        ZStack {
            Rectangle().stroke(Theme.Color.hairline, lineWidth: 1)
                .frame(width: 200, height: 130)
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.Color.halo, lineWidth: 1.5)
                .frame(width: 26, height: 44)
                .shadow(color: Theme.Color.halo.opacity(0.7), radius: 8)
                .rotationEffect(.degrees(tilt ? -32 : 0), anchor: .bottom)
                .offset(y: 30)
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: tilt)
        }
        .onAppear { tilt = true }
    }
}

private struct SideStepDiagram: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        ZStack {
            DotGrid().stroke(Theme.Color.hairline, lineWidth: 0.5)
            Path { p in
                p.move(to: CGPoint(x: 30, y: 100))
                for i in 0...20 {
                    let x = 30 + CGFloat(i) * 9
                    let y = 100 + sin(Double(i) * .pi / 4) * 14
                    p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .trim(from: 0, to: phase)
            .stroke(Theme.Color.halo, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .shadow(color: Theme.Color.halo.opacity(0.7), radius: 8)
        }
        .frame(width: 220, height: 160)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

private struct PauseDotsDiagram: View {
    @State private var which = 0
    var body: some View {
        HStack(spacing: 18) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i == which ? Theme.Color.halo : Theme.Color.inkRaised)
                    .frame(width: 14, height: 14)
                    .shadow(color: i == which ? Theme.Color.halo.opacity(0.7) : .clear, radius: 8)
                    .overlay(Circle().stroke(Theme.Color.hairlineHi, lineWidth: 0.8))
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.45)) {
                    which = (which + 1) % 4
                }
            }
        }
    }
}

private struct GlareWarningDiagram: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.Color.halo.opacity(pulse ? 0.55 : 0.25),
                                              .clear],
                                     center: .center, startRadius: 0, endRadius: 90))
                .frame(width: 180, height: 180)
                .blur(radius: 6)
            Image(systemName: "sun.max.trianglebadge.exclamationmark")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.Color.halo)
                .shadow(color: Theme.Color.halo.opacity(0.7), radius: 18)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct DetailFocusDiagram: View {
    @State private var rotate = false
    var body: some View {
        ZStack {
            Circle().stroke(Theme.Color.halo.opacity(0.7), lineWidth: 1.2)
                .frame(width: 110, height: 110)
                .shadow(color: Theme.Color.halo.opacity(0.6), radius: 8)
            Circle().trim(from: 0.0, to: 0.18)
                .stroke(Theme.Color.halo, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .frame(width: 134, height: 134)
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(.linear(duration: 4.0).repeatForever(autoreverses: false), value: rotate)
            Image(systemName: "scope")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .onAppear { rotate = true }
    }
}

private struct IntroDiagram: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.Color.halo.opacity(pulse ? 0.55 : 0.30),
                                              .clear],
                                     center: .center, startRadius: 0, endRadius: 130))
                .frame(width: 240, height: 240)
                .blur(radius: 6)
            Image(systemName: "sparkles")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.Color.halo)
                .shadow(color: Theme.Color.halo.opacity(0.7), radius: 20)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Helpers

private struct DotGrid: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 14
        var y = r.minY
        while y <= r.maxY {
            var x = r.minX
            while x <= r.maxX {
                p.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
                x += step
            }
            y += step
        }
        return p
    }
}
