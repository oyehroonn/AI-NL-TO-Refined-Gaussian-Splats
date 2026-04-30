//
//  LoopClosureDetector.swift
//  Real ARWorldMap-aware loop-closure detection.
//
//  The "real" worldMap signal isn't a single ARKit event — it's the
//  composition of:
//    1) frame.worldMappingStatus reaching .mapped  (ARKit is confident)
//    2) the user has actually been to multiple places (translation history)
//    3) the user has returned near the start position
//
//  We also export the actual ARWorldMap to disk at session end via
//  ARSession.getCurrentWorldMap(...). That file becomes a sidecar in the
//  capture package; AR-Layer 4 (pose bridge) consumes it for reconstruction.
//

import ARKit
import Foundation
import simd

@MainActor
final class LoopClosureDetector {

    private(set) var loopClosed: Bool = false
    private(set) var firstPose: simd_float4x4?
    private(set) var hasReachedMapped: Bool = false
    private(set) var maxYawSweepRadians: Float = 0
    /// Path samples — coarse breadcrumb of the camera's translation over time.
    private var pathSamples: [SIMD3<Float>] = []

    /// Threshold below which "we're back near the start" counts as closing.
    var returnDistanceThresholdMeters: Float = 1.0

    /// Threshold the yaw range must reach before a return-to-start counts
    /// as a real loop (otherwise standing still satisfies the geometric
    /// closure trivially).
    var minimumYawSweepRadians: Float = .pi * 1.5     // 270°

    /// Update with the latest ARFrame. Cheap; safe to call every frame.
    func observe(frame: ARFrame) {
        if firstPose == nil {
            firstPose = frame.camera.transform
        }
        if frame.worldMappingStatus == .mapped {
            hasReachedMapped = true
        }

        // Record the yaw range visited. We track yaw relative to start.
        if let start = firstPose {
            let dy = normalizeAngle(frame.camera.transform.yaw - start.yaw)
            let abs = Swift.abs(dy)
            if abs > maxYawSweepRadians {
                maxYawSweepRadians = abs
            }
        }

        // Sparse path samples — at most every 0.25 m moved.
        if let last = pathSamples.last {
            let p = frame.camera.transform.translation
            let d = simd_distance(last, p)
            if d > 0.25 {
                pathSamples.append(p)
            }
        } else {
            pathSamples.append(frame.camera.transform.translation)
        }

        // Closure check — only fires after we've moved & swept yaw enough.
        if !loopClosed,
           pathSamples.count >= 4,
           maxYawSweepRadians >= minimumYawSweepRadians,
           let start = firstPose {
            let here = frame.camera.transform.translation
            let backNearStart = simd_distance(here, start.translation) < returnDistanceThresholdMeters
            // Require ARKit to be confident in its map AND the user is back
            // near the origin AND has actually moved away in between (≥ 1 m
            // peak distance), so a static scan doesn't trivially "close".
            let peakAway = pathSamples.map { simd_distance(start.translation, $0) }.max() ?? 0
            if hasReachedMapped, backNearStart, peakAway > 1.0 {
                loopClosed = true
            }
        }
    }

    /// Reset for a fresh session (rare; caller usually creates a new instance).
    func reset() {
        loopClosed = false
        firstPose = nil
        hasReachedMapped = false
        maxYawSweepRadians = 0
        pathSamples.removeAll()
    }

    // MARK: - World map export

    /// Asks ARKit for the latest world map and writes it to `url`. Async because
    /// `getCurrentWorldMap` is itself async on a background thread.
    func exportWorldMap(from session: ARSession, to url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.getCurrentWorldMap { map, error in
                defer { cont.resume() }
                if let error = error {
                    NSLog("[LoopClosure] getCurrentWorldMap failed: \(error.localizedDescription)")
                    return
                }
                guard let map = map else { return }
                do {
                    let data = try NSKeyedArchiver.archivedData(
                        withRootObject: map,
                        requiringSecureCoding: true
                    )
                    try data.write(to: url, options: .atomic)
                } catch {
                    NSLog("[LoopClosure] worldMap write failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

private func normalizeAngle(_ a: Float) -> Float {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    if x < -.pi { x += 2 * .pi }
    return x
}
