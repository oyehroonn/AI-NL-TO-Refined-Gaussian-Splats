//
//  ModeCopy.swift
//  Per-mode tutorial steps. Each step has a short headline, a body line,
//  an SF Symbol used as a foreground accent, and a path-pattern hint that
//  tells ModeDiagrams which animated diagram to draw behind it.
//

import Foundation

struct TutorialStep: Equatable, Hashable, Identifiable {
    let id: String              // stable, mode-prefixed
    let headline: String
    let body: String
    let symbol: String          // SF Symbol name used as the small badge
    let diagramID: String       // matches ModeDiagrams id
}

enum ModeCopy {

    /// 4–5 steps per mode. The first 1–2 are mode-specific; the last 2–3 are
    /// the universal "move slowly / cover near & far / stop when full" baseline.
    static func steps(for mode: CaptureMode) -> [TutorialStep] {
        let universalTail: [TutorialStep] = [
            TutorialStep(
                id: "\(mode.scanModeID).slow",
                headline: "Move slowly",
                body: "Walking pace, not running pace. Sharp frames beat extra frames.",
                symbol: "tortoise.fill",
                diagramID: "speed_meter"
            ),
            TutorialStep(
                id: "\(mode.scanModeID).near_far",
                headline: "Cover near and far",
                body: "Step in close once, then back away. Both distances matter.",
                symbol: "arrow.up.left.and.down.right.magnifyingglass",
                diagramID: "near_far_arrows"
            ),
            TutorialStep(
                id: "\(mode.scanModeID).stop_when_full",
                headline: "Stop when coverage is full",
                body: "The HUD fills in as you move. Don't watch the timer — watch the fog clear.",
                symbol: "checkmark.circle.fill",
                diagramID: "coverage_fill"
            ),
        ]

        switch mode.scanModeID {
        case CaptureMode.object.scanModeID:
            return [
                TutorialStep(
                    id: "object.orbit",
                    headline: "Two full orbits",
                    body: "Walk a full circle around the object. Then a second pass at chest height, tilted slightly down.",
                    symbol: "arrow.triangle.2.circlepath",
                    diagramID: PathPattern.orbit
                ),
                TutorialStep(
                    id: "object.distance",
                    headline: "Stay 0.4 to 1.5 m away",
                    body: "Don't get glued to the object. Each frame should be a new view.",
                    symbol: "ruler.fill",
                    diagramID: "distance_band"
                ),
            ] + universalTail

        case CaptureMode.turntable.scanModeID:
            return [
                TutorialStep(
                    id: "turntable.steady",
                    headline: "Phone steady — object rotates",
                    body: "Hold the phone with both hands. Rotate the object in front of it slowly.",
                    symbol: "hands.sparkles.fill",
                    diagramID: PathPattern.rotationOnlyObject
                ),
                TutorialStep(
                    id: "turntable.tilt",
                    headline: "Tilt and re-rotate",
                    body: "Stop, tilt the phone slightly, rotate the object once more. Avoid your hand crossing in front.",
                    symbol: "hand.raised.slash.fill",
                    diagramID: "tilt_rotate"
                ),
            ] + universalTail

        case CaptureMode.room.scanModeID:
            return [
                TutorialStep(
                    id: "room.perimeter",
                    headline: "Perimeter first, corners second",
                    body: "Hug the walls all the way around. Then visit each corner up close.",
                    symbol: "rectangle.dashed",
                    diagramID: PathPattern.perimeterThenCenter
                ),
                TutorialStep(
                    id: "room.upper",
                    headline: "Get the upper corners",
                    body: "Tilt the phone up at each corner — ceiling joints are where splats fall apart most.",
                    symbol: "arrow.up.right",
                    diagramID: "tilt_ceiling"
                ),
            ] + universalTail

        case CaptureMode.largeIndoor.scanModeID:
            return [
                TutorialStep(
                    id: "large.wide_arcs",
                    headline: "Wide arcs, not tight circles",
                    body: "Big spaces fail when you orbit too tightly. Sweep gently across the volume.",
                    symbol: "circle.dashed",
                    diagramID: PathPattern.wideArc
                ),
                TutorialStep(
                    id: "large.stops",
                    headline: "Pause briefly in 3–4 spots",
                    body: "Brief stops let tracking lock. Don't stand still longer than 2 seconds.",
                    symbol: "pause.circle",
                    diagramID: "pause_dots"
                ),
            ] + universalTail

        case CaptureMode.corridor.scanModeID:
            return [
                TutorialStep(
                    id: "corridor.two_passes",
                    headline: "Walk through, then walk back",
                    body: "One pass forward, one pass returning. Don't sprint — slow walk for sharp frames.",
                    symbol: "arrow.left.arrow.right",
                    diagramID: PathPattern.corridorForwardBack
                ),
                TutorialStep(
                    id: "corridor.side_to_side",
                    headline: "Step side to side a little",
                    body: "Tiny lateral motion while walking gives the splat depth cues you can't fake.",
                    symbol: "arrow.left.and.right",
                    diagramID: "side_step"
                ),
            ] + universalTail

        case CaptureMode.storefront.scanModeID:
            return [
                TutorialStep(
                    id: "storefront.entry",
                    headline: "Doorway in, sweep wide",
                    body: "Start at the door. Walk inside, sweep left then right across shelves and floor.",
                    symbol: "door.left.hand.open",
                    diagramID: PathPattern.corridorForwardBack
                ),
                TutorialStep(
                    id: "storefront.glare",
                    headline: "Avoid windows and screens",
                    body: "Reflective surfaces make splats fall apart. Aim away from them.",
                    symbol: "sun.max.trianglebadge.exclamationmark",
                    diagramID: "glare_warning"
                ),
            ] + universalTail

        case CaptureMode.facade.scanModeID:
            return [
                TutorialStep(
                    id: "facade.lateral",
                    headline: "Walk parallel to the wall",
                    body: "Full length, then a second pass closer in for fine details.",
                    symbol: "arrow.right",
                    diagramID: PathPattern.facadeSweep
                ),
                TutorialStep(
                    id: "facade.sun",
                    headline: "Keep the sun behind you",
                    body: "Harsh light blows out highlights. If you can, capture in shade or overcast.",
                    symbol: "sun.haze",
                    diagramID: "sun_position"
                ),
            ] + universalTail

        case CaptureMode.vehicle.scanModeID:
            return [
                TutorialStep(
                    id: "vehicle.two_heights",
                    headline: "Two laps at two heights",
                    body: "First lap knee-height. Second lap chest-height, tilted slightly down.",
                    symbol: "figure.walk",
                    diagramID: PathPattern.orbit
                ),
                TutorialStep(
                    id: "vehicle.detail",
                    headline: "Wheels, mirrors, bumpers",
                    body: "These are usually the worst-resolved areas. Get close to each.",
                    symbol: "scope",
                    diagramID: "detail_focus"
                ),
            ] + universalTail

        default:
            // Fallback to the same five universal steps.
            return [
                TutorialStep(
                    id: "fallback.move",
                    headline: "How you move = how good the splat looks",
                    body: "Slow, varied motion is the whole game. The next steps walk you through it.",
                    symbol: "sparkles",
                    diagramID: "intro"
                )
            ] + universalTail
        }
    }
}
