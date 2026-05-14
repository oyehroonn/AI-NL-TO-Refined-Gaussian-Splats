//
//  SyntheticBakeScene.swift
//  Splattr — Gold Tier Perfection (Phase A1, debug surface).
//
//  "Run Test Bake" debug action — feeds MeshAtlasBaker.bake a known-good
//  3-triangle scene plus a single hand-coded checkerboard candidate view.
//  The resulting atlas should be a recognisable checkerboard. If it
//  comes out flat grey, the bug is 100 % inside the bake — eliminates
//  ARKit / CandidateViewPool / TexturedMeshRenderer as variables.
//
//  This is the single most valuable diagnostic in Phase A1 because it
//  removes the slowest part of every previous investigation: setting up
//  a real device scan to repro before each fix attempt.
//
//  Output:
//   - The full BakedMesh dropped to ArtifactDumper (atlas as PNG,
//     chosenViews as text, brightness report alongside).
//   - DebugLog summary so the user can read "checkerboard hit / missed"
//     directly in the HUD log share.
//

import Foundation
import Metal
import simd
import UIKit

enum SyntheticBakeScene {

    enum SyntheticError: Error {
        case noMetalDevice
        case textureAllocFailed
        case snapshotIndexBufferFailed
        case bakeThrew(Error)
    }

    /// Run end-to-end. Must be called from the main actor (BakeMetrics
    /// is `@MainActor`-isolated and the function mutates it up-front).
    /// The bake itself runs on a background `Task.detached` internally
    /// so the caller doesn't block. Result is delivered on main.
    @MainActor
    static func run(completion: @escaping (Result<String, SyntheticError>) -> Void) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            completion(.failure(.noMetalDevice))
            return
        }
        DebugLog.shared.info("synthetic", "starting test bake")
        BakeMetrics.shared.reset()
        BakeMetrics.shared.phase = "synthetic-setup"

        do {
            let snapshots = try buildSnapshots()
            let candidates = try buildCandidates(device: device)

            // Dump the candidate slice IMMEDIATELY — proves the
            // checkerboard actually made it into the texture array
            // before the bake even reads from it.
            ArtifactDumper.dumpTextureSlice(
                candidates.textureArray, slice: 0,
                as: "synthetic_candidate_slice_0"
            )

            Task.detached(priority: .userInitiated) {
                do {
                    // `Task.detached` runs OFF the main actor, but
                    // BakeMetrics is @MainActor-isolated — hop back
                    // explicitly for the one-line state update before
                    // the long-running bake kernel begins.
                    await MainActor.run {
                        BakeMetrics.shared.phase = "synthetic-bake"
                    }
                    let baked = try MeshAtlasBaker.bake(
                        snapshots: snapshots,
                        candidateViews: candidates,
                        onProgress: { phase, frac in
                            Task { @MainActor in
                                BakeMetrics.shared.phase = phase.label
                                BakeMetrics.shared.phaseProgress = frac
                            }
                        }
                    )

                    let summary = summarize(baked: baked)
                    await MainActor.run {
                        BakeMetrics.shared.phase = "synthetic-done"
                        BakeMetrics.shared.phaseProgress = 1.0
                        completion(.success(summary))
                    }
                } catch {
                    DebugLog.shared.error("synthetic",
                                           "bake threw \(error)")
                    await MainActor.run {
                        BakeMetrics.shared.phase = "synthetic-error"
                        completion(.failure(.bakeThrew(error)))
                    }
                }
            }
        } catch {
            completion(.failure(error as? SyntheticError ?? .bakeThrew(error)))
        }
    }

    // MARK: - Synthetic snapshot

    /// Builds a single ExplorerSnapshot with 3 triangles arranged in a
    /// 1×1 m square (split into two triangles) plus a third triangle
    /// off to the right. Three triangles is enough to exercise the
    /// atlas's tile-corner UV path without flooding the atlas. UVs are
    /// computed by the baker; we only supply vertex positions + index
    /// buffer.
    private static func buildSnapshots() throws ->
        [TexturedMeshRenderer.ExplorerSnapshot] {

        // Vertices in anchor-local space (anchor transform = identity).
        let verts: [SIMD3<Float>] = [
            SIMD3(-0.5, -0.5, -1.0),     // 0  square bottom-left
            SIMD3( 0.5, -0.5, -1.0),     // 1  square bottom-right
            SIMD3( 0.5,  0.5, -1.0),     // 2  square top-right
            SIMD3(-0.5,  0.5, -1.0),     // 3  square top-left
            SIMD3( 1.5,  0.5, -1.0),     // 4  triangle off to right (apex)
        ]
        let vertexData = verts.withUnsafeBufferPointer { Data(buffer: $0) }

        // Index buffer: UInt32. Two square triangles + one side triangle.
        let indices: [UInt32] = [
            0, 1, 2,         // square lower
            0, 2, 3,         // square upper
            1, 4, 2          // side triangle
        ]
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }

        // World AABB is the same as local (transform = identity).
        let wmin = SIMD3<Float>(-0.5, -0.5, -1.0)
        let wmax = SIMD3<Float>( 1.5,  0.5, -1.0)

        // A 1×1 placeholder UIImage — never read by the bake itself but
        // ExplorerSnapshot's contract requires one. The bake uses the
        // candidate view texture array, not this image, for sampling.
        let placeholder = UIImage(systemName: "questionmark.square") ?? UIImage()

        let snap = TexturedMeshRenderer.ExplorerSnapshot(
            worldTransform: matrix_identity_float4x4,
            vertexData: vertexData,
            vertexCount: verts.count,
            normalData: Data(),
            normalCount: 0,
            indexData: indexData,
            triangleCount: 3,
            bytesPerIndex: 4,
            uvData: Data(),
            worldMin: wmin, worldMax: wmax,
            textureImage: placeholder
        )
        return [snap]
    }

    // MARK: - Synthetic candidate view

    /// One CandidateViewSnapshot containing a single hand-coded
    /// checkerboard slice + a camera at (0, 0, 0) looking down -Z with a
    /// 60° vertical FOV. With the synthetic vertices at z = -1, the
    /// square fills the centre of the frame.
    private static func buildCandidates(
        device: MTLDevice
    ) throws -> CandidateViewSnapshot {

        // ── Build a 256×256 checkerboard texture array (1 slice) ─────
        let w = 256, h = 256
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        let squareSize = 32   // 8×8 squares across
        for y in 0..<h {
            for x in 0..<w {
                let cx = x / squareSize
                let cy = y / squareSize
                // Alternate strong red & strong cyan so the result is
                // instantly recognisable in a Mac Preview window.
                let isRed = ((cx + cy) & 1) == 0
                let off = (y * w + x) * 4
                if isRed {
                    bytes[off + 0] = 60    // B
                    bytes[off + 1] = 60    // G
                    bytes[off + 2] = 240   // R
                    bytes[off + 3] = 255   // A
                } else {
                    bytes[off + 0] = 220
                    bytes[off + 1] = 220
                    bytes[off + 2] = 60
                    bytes[off + 3] = 255
                }
            }
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .bgra8Unorm_srgb
        desc.width = w
        desc.height = h
        desc.arrayLength = 1
        // .shaderRead alone is fine because we upload via `replace` (CPU
        // memcpy, not a blit). Same code path CandidateViewPool uses.
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw SyntheticError.textureAllocFailed
        }
        let region = MTLRegionMake2D(0, 0, w, h)
        tex.replace(region: region,
                    mipmapLevel: 0, slice: 0,
                    withBytes: bytes,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerRow * h)

        // ── Build the matching Frame metadata ─────────────────────────
        // Camera at origin, looking down -Z.
        let camPos = SIMD3<Float>(0, 0, 0)
        let camFwd = SIMD3<Float>(0, 0, -1)
        let viewMatrix = simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        // projection: 60° vertical FOV, aspect 1, near 0.1, far 50.
        let fovY: Float = 60.0 * .pi / 180.0
        let aspect: Float = 1.0
        let near: Float = 0.1
        let far: Float  = 50.0
        let f = 1.0 / tan(fovY * 0.5)
        var proj = simd_float4x4(0)
        proj[0, 0] = f / aspect
        proj[1, 1] = f
        proj[2, 2] = far / (near - far)
        proj[2, 3] = -1
        proj[3, 2] = (far * near) / (near - far)

        let frame = CandidateViewPool.Frame(
            cameraTransform: matrix_identity_float4x4,
            viewMatrix: viewMatrix,
            projectionMatrix: proj,
            cameraPosition: camPos,
            cameraForward: camFwd,
            sharpness: 1.0,
            timestamp: 0,
            textureIndex: 0
        )

        return CandidateViewSnapshot(
            device: device,
            textureArray: tex,
            frames: [frame],
            thumbnailWidth: w,
            thumbnailHeight: h
        )
    }

    // MARK: - Reporting

    private static func summarize(baked: BakedMesh) -> String {
        var lines: [String] = []
        lines.append("=== SyntheticBakeScene summary ===")
        lines.append("atlases: \(baked.chunks.count)")
        lines.append("triangles: \(baked.stats.triangleCount)")
        lines.append("with view: \(baked.stats.trianglesWithView)")
        lines.append("sentinel : \(baked.stats.trianglesWithoutView)")
        lines.append("bake ms  : " +
                     "\(String(format: "%.1f", baked.stats.totalElapsed * 1000))")

        for (i, chunk) in baked.chunks.enumerated() {
            let tag = "synthetic_atlas_chunk_\(i)"
            ArtifactDumper.dumpUIImage(chunk.atlas, as: tag)
            if let stats = BakeDiagnostics.atlasBrightnessStats(chunk.atlas) {
                lines.append("--- chunk \(i) ---")
                lines.append(stats.description)
                Task { @MainActor in
                    BakeMetrics.shared.lastAtlasGreyFraction =
                        stats.greyFallbackFraction
                }
            }
        }

        let report = lines.joined(separator: "\n")
        ArtifactDumper.dumpText(report, as: "synthetic_summary")
        DebugLog.shared.info("synthetic", "test bake done; see artifacts dir")
        return report
    }
}
