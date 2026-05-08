//
//  CandidateViewPool.swift
//  Phase 2 — capture-time pool of "candidate views" used by MeshAtlasBaker.
//
//  Each candidate view = a downsized RGB thumbnail of the iPhone's camera
//  feed at the moment ARKit accepted a frame, plus the camera's world pose,
//  intrinsics-derived projection matrix, sharpness score, and timestamp.
//
//  Frames live in a single MTLTexture2DArray (one slice per frame, BGRA),
//  so the bake's Metal kernels can sample any candidate at GPU speed
//  without round-tripping bytes through the CPU.
//
//  Key invariants:
//   - All slices share one (W, H) — chosen on the first frame to preserve
//     the source sensor's aspect ratio. The stored projection matrix is
//     computed for that exact viewport size, so projecting a world point
//     through view × proj and converting NDC → UV gives the right
//     thumbnail texel.
//   - At most `maxFrames` slices are populated. New frames replace the
//     weakest (lowest-sharpness) frame already in the pool, never a
//     stronger one.
//   - A diversity filter rejects new frames that are nearly identical to
//     existing ones (within 10 cm AND with cos(forward) > 0.99). This
//     keeps the pool covering the room rather than oversampling one spot.
//
//  Snapshots produced by `snapshot()` share the underlying texture array
//  with the pool (no copy). Callers must pause the AR session before
//  taking the snapshot so the pool isn't mutated during baking.
//

import ARKit
import CoreImage
import Foundation
import Metal
import simd
import UIKit

@MainActor
final class CandidateViewPool {

    // MARK: - Per-frame metadata

    struct Frame {
        let cameraTransform: simd_float4x4
        let viewMatrix: simd_float4x4
        let projectionMatrix: simd_float4x4
        let cameraPosition: SIMD3<Float>
        let cameraForward: SIMD3<Float>
        let sharpness: Float
        let timestamp: TimeInterval
        /// Slice in `textureArray` where this frame's RGB lives.
        let textureIndex: Int
    }

    private(set) var frames: [Frame] = []
    private(set) var textureArray: MTLTexture?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    private let maxFrames: Int
    private(set) var thumbnailWidth: Int = 0
    private(set) var thumbnailHeight: Int = 0

    /// Currently-occupied slice indices. Lets us reuse a free slot before
    /// recycling old frames; relevant after eviction during a session.
    private var occupiedSlots: Set<Int> = []

    // MARK: - Init / reset

    init?(maxFrames: Int = 150, device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: dev,
                                    options: [.useSoftwareRenderer: false])
        self.maxFrames = maxFrames
    }

    func reset() {
        frames.removeAll()
        occupiedSlots.removeAll()
        // textureArray is reused — slices are simply marked unoccupied.
    }

    // MARK: - Add a candidate

    /// Consider `arFrame` for inclusion. Returns true if the frame was
    /// added (or replaced an existing one); false if redundant or upload
    /// failed. Caller passes the BlurDetector sharpness already computed
    /// upstream so we don't recompute it here.
    @discardableResult
    func consider(arFrame: ARFrame, sharpness rawSharpness: Double) -> Bool {
        let pixelBuffer = arFrame.capturedImage
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)

        // Lazy-allocate the texture array on the first acceptable frame so
        // its slice dimensions match the source aspect ratio.
        if textureArray == nil {
            initializeTextureArray(forSourceWidth: srcW, height: srcH)
            guard textureArray != nil else { return false }
        }
        // Defensive: reject any later frame whose source aspect doesn't
        // match what we initialized with. Should never happen mid-session.
        if abs(Double(srcW) / Double(srcH) -
               Double(thumbnailWidth) / Double(thumbnailHeight)) > 0.05 {
            return false
        }

        // Camera world pose for diversity test + later scoring.
        let xform = arFrame.camera.transform
        let camPos = SIMD3<Float>(xform.columns.3.x,
                                  xform.columns.3.y,
                                  xform.columns.3.z)
        let camFwd = simd_normalize(SIMD3<Float>(-xform.columns.2.x,
                                                  -xform.columns.2.y,
                                                  -xform.columns.2.z))

        // Diversity: skip if a similar frame is already in the pool.
        for f in frames {
            if simd_distance(camPos, f.cameraPosition) < 0.10 &&
               simd_dot(camFwd, f.cameraForward) > 0.99 {
                return false
            }
        }

        // Same normalisation curve as TexturedMeshRenderer so scores
        // produced by the live overlay and the bake are comparable.
        let sharp: Float = Float(min(1.0, max(0.0, rawSharpness / 200.0)))

        // Find a slot. If pool not yet full, take a free one. Otherwise
        // evict the weakest current frame — but only if the newcomer is
        // actually stronger.
        let slot: Int
        if frames.count < maxFrames {
            slot = nextFreeSlot()
        } else {
            var worstIdx = 0
            var worstSharp: Float = frames[0].sharpness
            for i in 1..<frames.count where frames[i].sharpness < worstSharp {
                worstIdx = i
                worstSharp = frames[i].sharpness
            }
            if sharp <= worstSharp { return false }
            slot = frames[worstIdx].textureIndex
            frames.remove(at: worstIdx)
            // slot stays occupied — we'll overwrite it.
        }

        guard uploadFrame(pixelBuffer: pixelBuffer, intoSlot: slot) else {
            return false
        }
        occupiedSlots.insert(slot)

        // Projection / view for the thumbnail's exact viewport size. The
        // thumbnail aspect was chosen to match source aspect so this is
        // self-consistent: NDC → UV → thumbnail texel maps cleanly.
        let viewSize = CGSize(width: thumbnailWidth, height: thumbnailHeight)
        let proj = arFrame.camera.projectionMatrix(
            for: .landscapeRight,
            viewportSize: viewSize,
            zNear: 0.05,
            zFar: 50.0
        )
        let view = arFrame.camera.viewMatrix(for: .landscapeRight)

        frames.append(Frame(
            cameraTransform: xform,
            viewMatrix: view,
            projectionMatrix: proj,
            cameraPosition: camPos,
            cameraForward: camFwd,
            sharpness: sharp,
            timestamp: arFrame.timestamp,
            textureIndex: slot
        ))
        return true
    }

    // MARK: - Snapshot (handoff to bake)

    /// Take an immutable handoff snapshot. Returns nil when the pool has
    /// no frames yet. The texture array is shared (no copy) — caller must
    /// pause the AR session so no further `consider(...)` calls overwrite
    /// slices while the bake reads them.
    func snapshot() -> CandidateViewSnapshot? {
        guard let arr = textureArray, !frames.isEmpty else { return nil }
        return CandidateViewSnapshot(
            device: device,
            textureArray: arr,
            frames: frames,
            thumbnailWidth: thumbnailWidth,
            thumbnailHeight: thumbnailHeight
        )
    }

    // MARK: - Internal

    private func nextFreeSlot() -> Int {
        for i in 0..<maxFrames where !occupiedSlots.contains(i) { return i }
        return 0
    }

    private func initializeTextureArray(forSourceWidth srcW: Int, height srcH: Int) {
        // Preserve source aspect ratio so projectionMatrix(viewport:...)
        // describes the same field of view as the actual sensor.
        let target = 256
        if srcW >= srcH {
            thumbnailHeight = target
            thumbnailWidth = max(1, (target * srcW + (srcH / 2)) / srcH)
        } else {
            thumbnailWidth = target
            thumbnailHeight = max(1, (target * srcH + (srcW / 2)) / srcW)
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .bgra8Unorm
        desc.width = thumbnailWidth
        desc.height = thumbnailHeight
        desc.arrayLength = maxFrames
        desc.usage = [.shaderRead]
        desc.storageMode = .private
        textureArray = device.makeTexture(descriptor: desc)
    }

    /// Render the source pixel buffer into a scratch BGRA texture and
    /// blit-copy it into slice `slot` of the texture array.
    private func uploadFrame(pixelBuffer: CVPixelBuffer, intoSlot slot: Int) -> Bool {
        guard let textureArray = textureArray,
              let cmd = commandQueue.makeCommandBuffer() else { return false }

        let scratchDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: thumbnailWidth,
            height: thumbnailHeight,
            mipmapped: false
        )
        scratchDesc.usage = [.shaderWrite, .renderTarget]
        scratchDesc.storageMode = .private
        guard let scratch = device.makeTexture(descriptor: scratchDesc) else {
            return false
        }

        // Uniform scale only (aspect already preserved by thumbnail size).
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ci.extent
        let scaleX = CGFloat(thumbnailWidth) / extent.width
        let scaleY = CGFloat(thumbnailHeight) / extent.height
        ci = ci.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let bounds = CGRect(x: 0, y: 0, width: thumbnailWidth, height: thumbnailHeight)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(ci, to: scratch, commandBuffer: cmd,
                          bounds: bounds, colorSpace: cs)

        guard let blit = cmd.makeBlitCommandEncoder() else { return false }
        blit.copy(
            from: scratch, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: thumbnailWidth, height: thumbnailHeight, depth: 1),
            to: textureArray, destinationSlice: slot, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        return true
    }
}

/// Immutable handoff to MeshAtlasBaker. Shares the pool's texture array
/// directly — caller must keep the pool stable for the snapshot's lifetime.
struct CandidateViewSnapshot {
    let device: MTLDevice
    let textureArray: MTLTexture
    let frames: [CandidateViewPool.Frame]
    let thumbnailWidth: Int
    let thumbnailHeight: Int
}
