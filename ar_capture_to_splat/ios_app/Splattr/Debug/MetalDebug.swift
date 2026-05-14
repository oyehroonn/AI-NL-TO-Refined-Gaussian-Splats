//
//  MetalDebug.swift
//  Splattr — Gold Tier Perfection (Phase A1, debug surface).
//
//  One Metal-side extension that REPLACES every bare
//  `cmd.commit() + cmd.waitUntilCompleted()` pair in the bake / candidate
//  upload paths.
//
//  Two classes of silent failure this catches that we saw historically:
//
//   * Silent blit no-op when a destination texture is missing
//     `.shaderWrite` usage. The MTLCommandBuffer completes without an
//     error and the texture stays zero-filled — see
//     `feedback_metal_blit_dest_usage.md`. With this wrapper, `cmd.error`
//     gets logged the moment it materializes (the Metal Validation
//     Layer, when enabled in the Xcode scheme, surfaces these as a
//     descriptive error string).
//
//   * Compute kernel divergence vs expectations: `gpuStartTime` /
//     `gpuEndTime` let us see exactly how long each sub-chunk took on
//     real device, not just CPU wall-clock. If a sub-chunk that "should
//     be 80 ms" is actually 4 s on a thermally-throttled phone, that
//     fact shows up in the log immediately.
//
//  Threading: the wrapper blocks the caller (waitUntilCompleted) just
//  like the bare pair it replaces. Caller is expected to already be on
//  a background `Task.detached` for the bake — this preserves that
//  contract.
//

import Foundation
import Metal

extension MTLCommandBuffer {

    /// Drop-in replacement for `commit() + waitUntilCompleted()` that
    /// logs the GPU-side timing + any post-commit error via
    /// `DebugLog.shared.gpu(...)` under the supplied tag.
    ///
    /// The wall-clock + GPU times are both logged because they answer
    /// different questions:
    ///   - wall = "did the caller stall longer than expected" (covers
    ///     command-queue contention vs other processes).
    ///   - gpu  = "did the kernel itself get slower" (covers thermal
    ///     throttling, kernel inefficiency).
    func commitAndCheck(tag: String, label: String) {
        let wallStart = CFAbsoluteTimeGetCurrent()
        commit()
        waitUntilCompleted()
        let wallEnd = CFAbsoluteTimeGetCurrent()

        // gpuStartTime / gpuEndTime are 0 until the buffer has actually
        // executed — safe to read after waitUntilCompleted.
        let gpuMs = max(0, (gpuEndTime - gpuStartTime) * 1000.0)
        let wallMs = (wallEnd - wallStart) * 1000.0

        if let err = error {
            DebugLog.shared.error(
                tag,
                "\(label): cmd error \(err.localizedDescription)"
            )
        } else {
            DebugLog.shared.gpu(
                tag,
                "\(label): gpu=\(String(format: "%.1f", gpuMs))ms " +
                "wall=\(String(format: "%.1f", wallMs))ms"
            )
        }
    }
}
