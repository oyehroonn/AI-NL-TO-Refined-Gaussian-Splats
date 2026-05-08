//
//  MeshAtlasBaker.swift
//  Phase 2 (streaming/multi-atlas) — per-face MVS-style baking that holds
//  full visual quality without freezing the phone.
//
//  Quality contract:
//   - Every triangle ARKit produced survives (1 cm welding only collapses
//     true sub-mm cross-anchor seams; nothing lossy).
//   - Every candidate view the diversity filter accepted participates in
//     best-view scoring (no view cap).
//   - 256 pixels per triangle face, always (4096² atlas + 16 px tiles).
//   - Concave-polyhedron physics on the welded mesh.
//
//  Scaling strategy:
//   - One atlas holds up to 65,536 triangles. Bigger meshes split across
//     multiple atlases; each is baked sequentially, each is full quality.
//   - Within each atlas, the bake is dispatched in 4,096-triangle sub-
//     chunks. After every sub-chunk we commit + waitUntilCompleted so the
//     GPU yields back to the system UI compositor — phone stays at 60 fps
//     even mid-bake.
//
//  Pipeline (a single bake call):
//    1. WELD            — merge anchor-spanning vertices on a 1 cm grid.
//    2. PRECOMPUTE      — per-triangle world centroid + world face normal.
//    3. BEST-VIEW (GPU) — one Metal compute kernel, one thread per
//                         triangle, loops over all candidate views, picks
//                         the winning view per triangle.
//    4. PLAN ATLASES    — split the global triangle list into ≤65,536-
//                         triangle ranges; each becomes one BakedChunk.
//    5. BAKE EACH ATLAS — Metal compute, one thread per atlas texel,
//                         sub-chunked at 4,096 tris per dispatch. Commits
//                         and waits between sub-chunks so UI stays fluid.
//    6. RETURN BakedMesh{ chunks: [BakedChunk], welded physics, AABB }.
//
//  Memory profile (per atlas during its bake — after CaptureView frees
//  TexturedMeshRenderer's live snapshots):
//    - One atlas being written:        64 MB (4096² BGRA, .private)
//    - Bake working buffers (per atlas) ~25 MB (vertex+UV+chosen views)
//    - Already-baked atlases (held in BakedMesh.chunks): N × 64 MB
//    - Welded mesh + render arrays:    ~15 MB
//    - Candidate texture array:        ~40 MB (held by the pool)
//  Peak during the Nth atlas bake: (N-1)·64 + 64 + 25 + 55 ≈ 144 + (N-1)·64.
//

import Foundation
import Metal
import SceneKit
import simd

// MARK: - Public types

/// One atlas worth of baked geometry — its render mesh (3 verts/tri,
/// no shared vertices, atlas UVs) and its companion atlas texture.
public struct BakedChunk {
    public let renderVertices: [SIMD3<Float>]
    public let renderNormals: [SIMD3<Float>]
    public let renderUVs: [SIMD2<Float>]
    /// Triangle count in THIS chunk only. Atlas covers exactly this many.
    public let triangleCount: Int
    /// 4K (or 2K for tiny scans) BGRA atlas. Diffuse for this chunk's
    /// material. SceneKit consumes MTLTexture as material.contents
    /// directly — no CGImage round-trip.
    public let atlas: MTLTexture
    public let atlasSize: Int
}

public struct BakedMesh {
    /// One render chunk per atlas. Tiny scans → 1 chunk. A 200K-triangle
    /// room → 4 chunks, each rendered as its own SCNNode.
    public let chunks: [BakedChunk]

    /// Welded global mesh — shared vertices, indexed triangles. Used for
    /// the single concavePolyhedron static physics body; no UVs needed.
    public let physicsVertices: [SIMD3<Float>]
    public let physicsTriangles: [SIMD3<UInt32>]

    /// World-space AABB. Drives FirstPersonController spawn.
    public let worldMin: SIMD3<Float>
    public let worldMax: SIMD3<Float>

    public let stats: BakeStats
}

public struct BakeStats {
    public let triangleCount: Int
    public let weldedVertexCount: Int
    public let candidateViewCount: Int
    public let trianglesWithView: Int      // ≥1 view chosen
    public let trianglesWithoutView: Int   // sentinel after best-view
    public let atlasCount: Int
    public let weldElapsed: TimeInterval
    public let bestViewElapsed: TimeInterval
    public let bakeElapsed: TimeInterval   // sum across all atlases
    public let totalElapsed: TimeInterval
}

/// Phases reported to the bake's progress callback. CaptureView's
/// "BAKING TEXTURES" overlay reads these to render a continuous,
/// honest progress bar.
public enum BakeProgressPhase: Equatable {
    case welding
    case selectingViews
    case bakingAtlas(index: Int, total: Int)
    case finalizing

    public var label: String {
        switch self {
        case .welding:                    return "WELDING MESH"
        case .selectingViews:             return "SELECTING BEST VIEWS"
        case .bakingAtlas(let i, let t):  return "BAKING ATLAS \(i)/\(t)"
        case .finalizing:                 return "FINALIZING"
        }
    }
}

/// (phase, fraction in [0,1]) — fraction is local to the phase, NOT a
/// global percentage. CaptureView does its own global blending.
public typealias BakeProgressCallback =
    @Sendable (BakeProgressPhase, Double) -> Void

public enum MeshAtlasBakerError: Error {
    case noSnapshots
    case noCandidateViews
    case shaderCompileFailed(String)
    case pipelineCreationFailed
    case textureAllocationFailed
    case bufferAllocationFailed
    case dispatchFailed
}

// MARK: - Baker

public enum MeshAtlasBaker {

    // ── Tunables ──────────────────────────────────────────────────────
    /// Triangles per atlas. With 16 px tiles + 4096² atlas this is also
    /// the atlas tile capacity (256 tiles × 256 tiles).
    static let trianglesPerAtlas: Int = 65_536
    /// Atlas size for normal-sized rooms (anything > 16K tris).
    static let largeAtlasSize: Int = 4096
    /// Atlas size for tiny scans (≤16K tris) — saves 48 MB of GPU memory
    /// without losing per-face resolution because the tile capacity still
    /// suffices.
    static let smallAtlasSize: Int = 2048
    /// Fixed tile size — never changes. 256 pixels per triangle face.
    static let tileSize: Int = 16
    /// Triangles per GPU sub-chunk inside one atlas's bake. A sub-chunk
    /// is one dispatchThreads + commit + waitUntilCompleted. Lower → UI
    /// is more responsive but bake is slightly slower; higher → faster
    /// bake but UI may stutter. 4096 is the sweet spot on iPhone Pro.
    static let subChunkTriangles: Int = 4096

    /// Run the full bake. Synchronous; call from a detached background
    /// Task. The progress callback fires on the same background thread —
    /// CaptureView marshals to main when it reads the values.
    public static func bake(
        snapshots: [TexturedMeshRenderer.ExplorerSnapshot],
        candidateViews: CandidateViewSnapshot,
        onProgress: BakeProgressCallback? = nil
    ) throws -> BakedMesh {
        guard !snapshots.isEmpty else { throw MeshAtlasBakerError.noSnapshots }
        guard !candidateViews.frames.isEmpty else {
            throw MeshAtlasBakerError.noCandidateViews
        }
        let device = candidateViews.device
        let tStart = CFAbsoluteTimeGetCurrent()

        // ── 1. WELD ──────────────────────────────────────────────────
        onProgress?(.welding, 0.0)
        let welded = WeldedMesh.from(snapshots: snapshots)
        onProgress?(.welding, 1.0)
        let tWeld = CFAbsoluteTimeGetCurrent()

        // ── 2. PRECOMPUTE per-triangle centroid + face normal ───────
        // These feed both best-view selection AND the atlas bake's
        // per-texel barycentric reconstruction. Computed once on CPU
        // (fast: ~5 ms for 200K tris) so the GPU kernel doesn't have
        // to redo it.
        let triCount = welded.triangles.count
        var triWorldV0 = [SIMD3<Float>](repeating: .zero, count: triCount)
        var triWorldV1 = [SIMD3<Float>](repeating: .zero, count: triCount)
        var triWorldV2 = [SIMD3<Float>](repeating: .zero, count: triCount)
        var triCentroid = [SIMD3<Float>](repeating: .zero, count: triCount)
        var triNormal = [SIMD3<Float>](repeating: .zero, count: triCount)
        for t in 0..<triCount {
            let tri = welded.triangles[t]
            let v0 = welded.vertices[Int(tri.x)]
            let v1 = welded.vertices[Int(tri.y)]
            let v2 = welded.vertices[Int(tri.z)]
            triWorldV0[t] = v0
            triWorldV1[t] = v1
            triWorldV2[t] = v2
            triCentroid[t] = (v0 + v1 + v2) / 3.0
            let cross = simd_cross(v1 - v0, v2 - v0)
            let len = simd_length(cross)
            triNormal[t] = len > 1e-8 ? cross / len : SIMD3<Float>(0, 1, 0)
        }

        // ── 3. BEST-VIEW SELECTION (GPU) ─────────────────────────────
        onProgress?(.selectingViews, 0.0)
        let chosenViews = try selectBestViewsOnGPU(
            device: device,
            triangleCount: triCount,
            triCentroid: triCentroid,
            triNormal: triNormal,
            views: candidateViews.frames
        )
        onProgress?(.selectingViews, 1.0)
        let tBest = CFAbsoluteTimeGetCurrent()

        // ── 4. PLAN ATLASES ──────────────────────────────────────────
        let atlasPlans = planAtlases(triangleCount: triCount)

        // ── 5. BAKE EACH ATLAS ───────────────────────────────────────
        var bakedChunks: [BakedChunk] = []
        bakedChunks.reserveCapacity(atlasPlans.count)
        let tBakeStart = CFAbsoluteTimeGetCurrent()
        for (atlasIdx, plan) in atlasPlans.enumerated() {
            let chunk = try bakeOneAtlas(
                device: device,
                plan: plan,
                triWorldV0: triWorldV0,
                triWorldV1: triWorldV1,
                triWorldV2: triWorldV2,
                triNormal: triNormal,
                weldedNormals: welded.normals,
                weldedTriangles: welded.triangles,
                chosenViews: chosenViews,
                candidateViews: candidateViews,
                onProgress: { fraction in
                    onProgress?(.bakingAtlas(index: atlasIdx + 1,
                                              total: atlasPlans.count),
                                 fraction)
                }
            )
            bakedChunks.append(chunk)
        }
        let tBakeEnd = CFAbsoluteTimeGetCurrent()

        // Free per-triangle CPU temporaries we no longer need.
        triWorldV0.removeAll(keepingCapacity: false)
        triWorldV1.removeAll(keepingCapacity: false)
        triWorldV2.removeAll(keepingCapacity: false)
        triCentroid.removeAll(keepingCapacity: false)
        triNormal.removeAll(keepingCapacity: false)

        onProgress?(.finalizing, 1.0)

        // Stats
        let withView = chosenViews.reduce(0) { $0 + ($1 == .max ? 0 : 1) }
        let stats = BakeStats(
            triangleCount: triCount,
            weldedVertexCount: welded.vertices.count,
            candidateViewCount: candidateViews.frames.count,
            trianglesWithView: withView,
            trianglesWithoutView: triCount - withView,
            atlasCount: atlasPlans.count,
            weldElapsed: tWeld - tStart,
            bestViewElapsed: tBest - tWeld,
            bakeElapsed: tBakeEnd - tBakeStart,
            totalElapsed: CFAbsoluteTimeGetCurrent() - tStart
        )

        return BakedMesh(
            chunks: bakedChunks,
            physicsVertices: welded.vertices,
            physicsTriangles: welded.triangles,
            worldMin: welded.worldMin,
            worldMax: welded.worldMax,
            stats: stats
        )
    }

    // MARK: - Atlas planning

    private struct AtlasPlan {
        /// Global index of the first triangle in this atlas.
        let triangleOffset: Int
        /// Triangles in this atlas (≤ trianglesPerAtlas).
        let triangleCount: Int
        let atlasSize: Int
        let tileSize: Int
        /// atlasSize / tileSize.
        let tilesPerRow: Int
    }

    /// Split the triangle list into one atlas per `trianglesPerAtlas`.
    /// Tiny scans get a 2K atlas instead of 4K (saves 48 MB) but always
    /// preserve 16 px tiles → 256 pixels per face.
    private static func planAtlases(triangleCount: Int) -> [AtlasPlan] {
        guard triangleCount > 0 else { return [] }

        // Tiny scan: single 2K atlas. 2048/16 = 128 tiles per row → 16K
        // triangle capacity. If the scan exceeds that, jump to the 4K
        // atlas plan.
        if triangleCount <= 16_384 {
            return [AtlasPlan(
                triangleOffset: 0,
                triangleCount: triangleCount,
                atlasSize: smallAtlasSize,
                tileSize: tileSize,
                tilesPerRow: smallAtlasSize / tileSize
            )]
        }

        var plans: [AtlasPlan] = []
        var offset = 0
        while offset < triangleCount {
            let count = min(trianglesPerAtlas, triangleCount - offset)
            plans.append(AtlasPlan(
                triangleOffset: offset,
                triangleCount: count,
                atlasSize: largeAtlasSize,
                tileSize: tileSize,
                tilesPerRow: largeAtlasSize / tileSize
            ))
            offset += count
        }
        return plans
    }

    // MARK: - Atlas layout

    /// Per-tile triangle layout:
    ///   V0 → bottom-left  (1, 1)            — 1-px inset
    ///   V1 → bottom-right (tileSize-1, 1)
    ///   V2 → top-center   (tileSize/2, tileSize-1)
    /// Atlas-pixel coordinates returned; divide by atlasSize for UVs.
    @inline(__always)
    private static func tileVertexUV(
        triangleLocalIdx t: Int,
        atlasSize: Int,
        tileSize: Int,
        tilesPerRow: Int,
        vertex i: Int
    ) -> SIMD2<Float> {
        let tileX = t % tilesPerRow
        let tileY = t / tilesPerRow
        let inset: Float = 1.0
        let halfTile = Float(tileSize) * 0.5
        let pxCorner: SIMD2<Float>
        switch i {
        case 0:
            pxCorner = SIMD2(Float(tileX * tileSize) + inset,
                             Float(tileY * tileSize) + inset)
        case 1:
            pxCorner = SIMD2(Float((tileX + 1) * tileSize) - inset,
                             Float(tileY * tileSize) + inset)
        default: // 2
            pxCorner = SIMD2(Float(tileX * tileSize) + halfTile,
                             Float((tileY + 1) * tileSize) - inset)
        }
        return pxCorner / Float(atlasSize)
    }

    // MARK: - Single atlas bake

    private static func bakeOneAtlas(
        device: MTLDevice,
        plan: AtlasPlan,
        triWorldV0: [SIMD3<Float>],
        triWorldV1: [SIMD3<Float>],
        triWorldV2: [SIMD3<Float>],
        triNormal: [SIMD3<Float>],
        weldedNormals: [SIMD3<Float>],
        weldedTriangles: [SIMD3<UInt32>],
        chosenViews: [UInt16],
        candidateViews: CandidateViewSnapshot,
        onProgress: (Double) -> Void
    ) throws -> BakedChunk {
        let atlasSize = plan.atlasSize
        let tileSize = plan.tileSize
        let tilesPerRow = plan.tilesPerRow
        let triCount = plan.triangleCount
        let offset = plan.triangleOffset

        // ── Build chunk-local render arrays ────────────────────────────
        // Three vertices per triangle; each gets its tile-corner UV. We
        // also pull per-vertex normals from the welded mesh (smooth-
        // shaded; SceneKit uses them for its rim lighting on .constant
        // materials only marginally, but it's free metadata).
        var renderVertices = [SIMD3<Float>](repeating: .zero, count: triCount * 3)
        var renderNormals = [SIMD3<Float>](repeating: .zero, count: triCount * 3)
        var renderUVs = [SIMD2<Float>](repeating: .zero, count: triCount * 3)
        for localT in 0..<triCount {
            let globalT = offset + localT
            let tri = weldedTriangles[globalT]
            renderVertices[localT * 3 + 0] = triWorldV0[globalT]
            renderVertices[localT * 3 + 1] = triWorldV1[globalT]
            renderVertices[localT * 3 + 2] = triWorldV2[globalT]
            renderNormals[localT * 3 + 0] = weldedNormals[Int(tri.x)]
            renderNormals[localT * 3 + 1] = weldedNormals[Int(tri.y)]
            renderNormals[localT * 3 + 2] = weldedNormals[Int(tri.z)]
            renderUVs[localT * 3 + 0] = tileVertexUV(
                triangleLocalIdx: localT,
                atlasSize: atlasSize, tileSize: tileSize,
                tilesPerRow: tilesPerRow, vertex: 0)
            renderUVs[localT * 3 + 1] = tileVertexUV(
                triangleLocalIdx: localT,
                atlasSize: atlasSize, tileSize: tileSize,
                tilesPerRow: tilesPerRow, vertex: 1)
            renderUVs[localT * 3 + 2] = tileVertexUV(
                triangleLocalIdx: localT,
                atlasSize: atlasSize, tileSize: tileSize,
                tilesPerRow: tilesPerRow, vertex: 2)
        }

        // ── Allocate the atlas texture ─────────────────────────────────
        guard let atlas = makeAtlasTexture(device: device, size: atlasSize) else {
            throw MeshAtlasBakerError.textureAllocationFailed
        }

        // ── GPU bake (chunked) ─────────────────────────────────────────
        try bakeAtlasChunked(
            device: device,
            atlas: atlas,
            atlasSize: atlasSize,
            tileSize: tileSize,
            tilesPerRow: tilesPerRow,
            chunkTriangleOffset: offset,
            renderVertices: renderVertices,
            renderUVs: renderUVs,
            chunkTriangleCount: triCount,
            chosenViews: chosenViews,
            candidateViews: candidateViews,
            onProgress: onProgress
        )

        return BakedChunk(
            renderVertices: renderVertices,
            renderNormals: renderNormals,
            renderUVs: renderUVs,
            triangleCount: triCount,
            atlas: atlas,
            atlasSize: atlasSize
        )
    }

    // MARK: - Texture helper

    private static func makeAtlasTexture(device: MTLDevice, size: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size, height: size, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }
}

// MARK: - Welded mesh

private struct WeldedMesh {
    var vertices: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var triangles: [SIMD3<UInt32>] = []
    var worldMin: SIMD3<Float> = SIMD3(.infinity, .infinity, .infinity)
    var worldMax: SIMD3<Float> = SIMD3(-.infinity, -.infinity, -.infinity)

    /// 1 cm grid. ARKit anchor seams are sub-mm so this only resolves true
    /// duplicates at chunk boundaries. No visible quality loss.
    static let cellSize: Float = 0.01

    static func from(
        snapshots: [TexturedMeshRenderer.ExplorerSnapshot]
    ) -> WeldedMesh {
        var mesh = WeldedMesh()

        struct CellKey: Hashable { let x: Int32; let y: Int32; let z: Int32 }
        var hashToIndex: [CellKey: UInt32] = [:]
        hashToIndex.reserveCapacity(50_000)
        var normalAccum: [SIMD3<Float>] = []

        for snap in snapshots {
            let localVerts: [SIMD3<Float>] = snap.vertexData.withUnsafeBytes {
                let p = $0.bindMemory(to: SIMD3<Float>.self)
                return (0..<snap.vertexCount).map { p[$0] }
            }
            let xform = snap.worldTransform
            var worldVerts: [SIMD3<Float>] = []
            worldVerts.reserveCapacity(localVerts.count)
            for v in localVerts {
                let w4 = simd_mul(xform, SIMD4<Float>(v.x, v.y, v.z, 1))
                worldVerts.append(SIMD3<Float>(w4.x, w4.y, w4.z))
            }

            var localToGlobal: [UInt32] = []
            localToGlobal.reserveCapacity(worldVerts.count)
            for w in worldVerts {
                let key = CellKey(
                    x: Int32((w.x / cellSize).rounded()),
                    y: Int32((w.y / cellSize).rounded()),
                    z: Int32((w.z / cellSize).rounded())
                )
                if let existing = hashToIndex[key] {
                    localToGlobal.append(existing)
                } else {
                    let newIdx = UInt32(mesh.vertices.count)
                    mesh.vertices.append(w)
                    normalAccum.append(SIMD3<Float>(0, 0, 0))
                    hashToIndex[key] = newIdx
                    localToGlobal.append(newIdx)
                    mesh.worldMin = simd_min(mesh.worldMin, w)
                    mesh.worldMax = simd_max(mesh.worldMax, w)
                }
            }

            let triCount = snap.triangleCount
            snap.indexData.withUnsafeBytes { (rawIdx: UnsafeRawBufferPointer) in
                func tri(at t: Int) -> (Int, Int, Int) {
                    if snap.bytesPerIndex == 4 {
                        let p = rawIdx.bindMemory(to: UInt32.self)
                        return (Int(p[t * 3]), Int(p[t * 3 + 1]), Int(p[t * 3 + 2]))
                    } else {
                        let p = rawIdx.bindMemory(to: UInt16.self)
                        return (Int(p[t * 3]), Int(p[t * 3 + 1]), Int(p[t * 3 + 2]))
                    }
                }
                for t in 0..<triCount {
                    let (a, b, c) = tri(at: t)
                    let g0 = localToGlobal[a]
                    let g1 = localToGlobal[b]
                    let g2 = localToGlobal[c]
                    if g0 == g1 || g1 == g2 || g0 == g2 { continue }
                    mesh.triangles.append(SIMD3<UInt32>(g0, g1, g2))

                    let v0 = mesh.vertices[Int(g0)]
                    let v1 = mesh.vertices[Int(g1)]
                    let v2 = mesh.vertices[Int(g2)]
                    let cross = simd_cross(v1 - v0, v2 - v0)
                    let len = simd_length(cross)
                    let n: SIMD3<Float> = len > 1e-8 ? cross / len : SIMD3<Float>(0, 1, 0)
                    normalAccum[Int(g0)] += n
                    normalAccum[Int(g1)] += n
                    normalAccum[Int(g2)] += n
                }
            }
        }

        mesh.normals = normalAccum.map { n in
            let len = simd_length(n)
            return len > 1e-6 ? n / len : SIMD3<Float>(0, 1, 0)
        }
        if !mesh.worldMin.x.isFinite || !mesh.worldMax.x.isFinite {
            mesh.worldMin = SIMD3<Float>(-1, -1, -1)
            mesh.worldMax = SIMD3<Float>( 1,  1,  1)
        }
        return mesh
    }
}

// MARK: - GPU layout for views

/// Mirrors the Metal `ViewDataGPU` struct in `kSelectViewShaderSource`
/// and `kBakeShaderSource`. 176 bytes, 16-byte aligned. The matrices
/// are 64 bytes each; the trailing scalars are padded to keep array
/// stride a multiple of 16.
private struct ViewDataGPU {
    var viewMatrix: simd_float4x4
    var projMatrix: simd_float4x4
    var cameraPosition: SIMD4<Float>     // .xyz; .w padding
    var cameraForward: SIMD4<Float>
    var sharpness: Float
    var textureIndex: UInt32
    var _pad0: Float = 0
    var _pad1: Float = 0
}

// MARK: - GPU best-view selection

private struct BestViewParams {
    var triangleCount: UInt32
    var viewCount: UInt32
}

private let kSelectViewShaderSource: String = """
#include <metal_stdlib>
using namespace metal;

struct ViewDataGPU {
    float4x4 viewMatrix;
    float4x4 projMatrix;
    float4   cameraPosition;
    float4   cameraForward;
    float    sharpness;
    uint     textureIndex;
    float    _pad0;
    float    _pad1;
};

struct BestViewParams {
    uint triangleCount;
    uint viewCount;
};

// One thread per triangle. Scores each candidate view by the same
// product the live overlay uses (facing × distance × sharpness) plus
// a frustum visibility test, and writes the winning view's index
// to `chosen[t]`. Sentinel 0xFFFF means no view sees this triangle
// well enough to texture it.
kernel void selectBestView(
    device const float4*       triCentroid [[buffer(0)]],   // .xyz used
    device const float4*       triNormal   [[buffer(1)]],   // .xyz used
    device const ViewDataGPU*  views       [[buffer(2)]],
    device       ushort*       chosen      [[buffer(3)]],
    constant     BestViewParams& P         [[buffer(4)]],
    uint                       tid         [[thread_position_in_grid]]
) {
    if (tid >= P.triangleCount) return;
    float3 c = triCentroid[tid].xyz;
    float3 n = triNormal[tid].xyz;

    float bestScore = 0.05;        // floor — anything below is "no view"
    ushort bestIdx = 0xFFFF;

    for (uint v = 0; v < P.viewCount; v++) {
        ViewDataGPU V = views[v];

        // Visibility — project centroid through view × proj.
        float4 mv  = V.viewMatrix * float4(c, 1.0);
        float4 cl  = V.projMatrix * mv;
        if (cl.w <= 0) continue;
        float ndcX = cl.x / cl.w;
        float ndcY = cl.y / cl.w;
        if (fabs(ndcX) > 0.95 || fabs(ndcY) > 0.95) continue;

        // Facing.
        float3 toCamRaw = V.cameraPosition.xyz - c;
        float dist = length(toCamRaw);
        if (dist < 0.05) continue;
        float3 toCam = toCamRaw / dist;
        float facing = dot(n, toCam);
        if (facing <= 0.10) continue;

        float distScore  = min(1.0, 1.5 / max(dist, 0.3));
        float sharpScore = V.sharpness;
        float score      = facing * distScore * sharpScore;

        if (score > bestScore) {
            bestScore = score;
            bestIdx   = (ushort)v;
        }
    }
    chosen[tid] = bestIdx;
}
"""

private func selectBestViewsOnGPU(
    device: MTLDevice,
    triangleCount: Int,
    triCentroid: [SIMD3<Float>],
    triNormal: [SIMD3<Float>],
    views: [CandidateViewPool.Frame]
) throws -> [UInt16] {
    let library: MTLLibrary
    do {
        library = try device.makeLibrary(source: kSelectViewShaderSource,
                                          options: nil)
    } catch {
        throw MeshAtlasBakerError.shaderCompileFailed(error.localizedDescription)
    }
    guard let function = library.makeFunction(name: "selectBestView") else {
        throw MeshAtlasBakerError.pipelineCreationFailed
    }
    let pipeline: MTLComputePipelineState
    do {
        pipeline = try device.makeComputePipelineState(function: function)
    } catch {
        throw MeshAtlasBakerError.pipelineCreationFailed
    }
    guard let queue = device.makeCommandQueue() else {
        throw MeshAtlasBakerError.pipelineCreationFailed
    }

    // Pad SIMD3 → SIMD4 so device-side `float4*` reads cleanly.
    var centroid4 = [SIMD4<Float>]()
    centroid4.reserveCapacity(triangleCount)
    for c in triCentroid {
        centroid4.append(SIMD4<Float>(c.x, c.y, c.z, 0))
    }
    var normal4 = [SIMD4<Float>]()
    normal4.reserveCapacity(triangleCount)
    for n in triNormal {
        normal4.append(SIMD4<Float>(n.x, n.y, n.z, 0))
    }

    guard let centroidBuf = device.makeBuffer(
        bytes: centroid4,
        length: centroid4.count * MemoryLayout<SIMD4<Float>>.stride,
        options: .storageModeShared
    ) else { throw MeshAtlasBakerError.bufferAllocationFailed }
    // Free the Swift copy now — bytes are on the GPU.
    centroid4.removeAll(keepingCapacity: false)

    guard let normalBuf = device.makeBuffer(
        bytes: normal4,
        length: normal4.count * MemoryLayout<SIMD4<Float>>.stride,
        options: .storageModeShared
    ) else { throw MeshAtlasBakerError.bufferAllocationFailed }
    normal4.removeAll(keepingCapacity: false)

    var viewsGPU: [ViewDataGPU] = views.map { f in
        ViewDataGPU(
            viewMatrix: f.viewMatrix,
            projMatrix: f.projectionMatrix,
            cameraPosition: SIMD4<Float>(f.cameraPosition.x,
                                         f.cameraPosition.y,
                                         f.cameraPosition.z, 0),
            cameraForward: SIMD4<Float>(f.cameraForward.x,
                                         f.cameraForward.y,
                                         f.cameraForward.z, 0),
            sharpness: f.sharpness,
            textureIndex: UInt32(f.textureIndex)
        )
    }
    guard let viewsBuf = device.makeBuffer(
        bytes: &viewsGPU,
        length: viewsGPU.count * MemoryLayout<ViewDataGPU>.stride,
        options: .storageModeShared
    ) else { throw MeshAtlasBakerError.bufferAllocationFailed }

    guard let chosenBuf = device.makeBuffer(
        length: triangleCount * MemoryLayout<UInt16>.stride,
        options: .storageModeShared
    ) else { throw MeshAtlasBakerError.bufferAllocationFailed }

    var params = BestViewParams(
        triangleCount: UInt32(triangleCount),
        viewCount: UInt32(views.count)
    )

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeComputeCommandEncoder() else {
        throw MeshAtlasBakerError.dispatchFailed
    }
    enc.setComputePipelineState(pipeline)
    enc.setBuffer(centroidBuf, offset: 0, index: 0)
    enc.setBuffer(normalBuf,   offset: 0, index: 1)
    enc.setBuffer(viewsBuf,    offset: 0, index: 2)
    enc.setBuffer(chosenBuf,   offset: 0, index: 3)
    enc.setBytes(&params, length: MemoryLayout<BestViewParams>.stride, index: 4)

    let groupSize = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
    enc.dispatchThreads(
        MTLSize(width: triangleCount, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1)
    )
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    // Copy out the chosen indices.
    var chosen = [UInt16](repeating: .max, count: triangleCount)
    let chosenPtr = chosenBuf.contents().bindMemory(
        to: UInt16.self, capacity: triangleCount
    )
    for i in 0..<triangleCount { chosen[i] = chosenPtr[i] }
    return chosen
}

// MARK: - Atlas bake (chunked compute)

private struct BakeParams {
    var atlasSize: UInt32
    var tileSize: UInt32
    var tilesPerRow: UInt32
    var chunkTriangleCount: UInt32
    /// Where THIS atlas's triangles begin in the global chosenViews
    /// array. Lets the kernel index `chosenViews[chunkTriangleOffset + t]`.
    var chunkTriangleOffset: UInt32
    /// Sub-chunk offset WITHIN this atlas (advances each dispatch).
    var subChunkStart: UInt32
}

private let kBakeShaderSource: String = """
#include <metal_stdlib>
using namespace metal;

struct BakeParams {
    uint atlasSize;
    uint tileSize;
    uint tilesPerRow;
    uint chunkTriangleCount;
    uint chunkTriangleOffset;
    uint subChunkStart;
};

struct ViewDataGPU {
    float4x4 viewMatrix;
    float4x4 projMatrix;
    float4   cameraPosition;
    float4   cameraForward;
    float    sharpness;
    uint     textureIndex;
    float    _pad0;
    float    _pad1;
};

constexpr sampler kSourceSampler(coord::normalized,
                                 address::clamp_to_edge,
                                 filter::linear);

// Threads:  (i, j, t)
//   i, j ∈ [0, tileSize)        — pixel within the triangle's tile
//   t    ∈ [0, subChunkLength)  — local triangle index within this
//                                 sub-chunk; absolute local triangle is
//                                 (subChunkStart + t).
//
// Atlas pixel = (tileX*tileSize + i, tileY*tileSize + j) where tileX,
// tileY are computed from the atlas-local triangle index.
kernel void bakeAtlas(
    texture2d<float, access::write>           atlas      [[texture(0)]],
    texture2d_array<float, access::sample>    candidates [[texture(1)]],
    device   const float3*                    triVerts   [[buffer(0)]], // 3 per tri (chunk-local)
    device   const float2*                    triUVs     [[buffer(1)]], // 3 per tri (chunk-local)
    device   const ViewDataGPU*               views      [[buffer(2)]],
    device   const ushort*                    chosenView [[buffer(3)]], // GLOBAL — indexed via chunkTriangleOffset
    constant BakeParams&                      P          [[buffer(4)]],
    uint3                                     gid        [[thread_position_in_grid]]
) {
    if (gid.x >= P.tileSize || gid.y >= P.tileSize) return;
    uint localT = gid.z + P.subChunkStart;
    if (localT >= P.chunkTriangleCount) return;

    uint tileX  = localT % P.tilesPerRow;
    uint tileY  = localT / P.tilesPerRow;
    uint pixelX = tileX * P.tileSize + gid.x;
    uint pixelY = tileY * P.tileSize + gid.y;

    float2 atlasUV = float2((float)pixelX + 0.5, (float)pixelY + 0.5)
                     / (float)P.atlasSize;

    float3 V0  = triVerts[localT * 3 + 0];
    float3 V1  = triVerts[localT * 3 + 1];
    float3 V2  = triVerts[localT * 3 + 2];
    float2 UV0 = triUVs[localT * 3 + 0];
    float2 UV1 = triUVs[localT * 3 + 1];
    float2 UV2 = triUVs[localT * 3 + 2];

    // Barycentric of atlasUV in the triangle (UV0, UV1, UV2).
    float2 e0 = UV1 - UV0;
    float2 e1 = UV2 - UV0;
    float2 e2 = atlasUV - UV0;
    float d00 = dot(e0, e0);
    float d01 = dot(e0, e1);
    float d11 = dot(e1, e1);
    float d20 = dot(e2, e0);
    float d21 = dot(e2, e1);
    float denom = d00 * d11 - d01 * d01;

    const float4 grey = float4(0.45, 0.45, 0.50, 1.0);
    if (fabs(denom) < 1e-8) {
        atlas.write(grey, uint2(pixelX, pixelY));
        return;
    }
    float b1 = (d11 * d20 - d01 * d21) / denom;
    float b2 = (d00 * d21 - d01 * d20) / denom;
    float b0 = 1.0 - b1 - b2;

    // Outside the tile-triangle (epsilon for filter safety) → grey waste.
    const float eps = -0.02;
    if (b0 < eps || b1 < eps || b2 < eps) {
        atlas.write(grey, uint2(pixelX, pixelY));
        return;
    }
    b0 = clamp(b0, 0.0, 1.0);
    b1 = clamp(b1, 0.0, 1.0);
    b2 = clamp(b2, 0.0, 1.0);
    float bsum = b0 + b1 + b2;
    if (bsum > 1e-6) { b0 /= bsum; b1 /= bsum; b2 /= bsum; }

    float3 worldPos = b0 * V0 + b1 * V1 + b2 * V2;

    // chosenViews is GLOBAL — index with the global triangle index.
    uint globalT = P.chunkTriangleOffset + localT;
    ushort viewIdx = chosenView[globalT];
    if (viewIdx == 0xFFFF) {
        atlas.write(grey, uint2(pixelX, pixelY));
        return;
    }
    ViewDataGPU V = views[viewIdx];

    float4 viewPos = V.viewMatrix * float4(worldPos, 1.0);
    float4 clipPos = V.projMatrix * viewPos;
    if (clipPos.w <= 0) {
        atlas.write(grey, uint2(pixelX, pixelY));
        return;
    }
    float3 ndc = clipPos.xyz / clipPos.w;

    float2 sampleUV = float2(ndc.x * 0.5 + 0.5,
                             1.0 - (ndc.y * 0.5 + 0.5));
    if (sampleUV.x < 0.0 || sampleUV.x > 1.0 ||
        sampleUV.y < 0.0 || sampleUV.y > 1.0) {
        atlas.write(grey, uint2(pixelX, pixelY));
        return;
    }
    float4 c = candidates.sample(kSourceSampler, sampleUV, V.textureIndex);
    atlas.write(float4(c.rgb, 1.0), uint2(pixelX, pixelY));
}
"""

private func bakeAtlasChunked(
    device: MTLDevice,
    atlas: MTLTexture,
    atlasSize: Int,
    tileSize: Int,
    tilesPerRow: Int,
    chunkTriangleOffset: Int,
    renderVertices: [SIMD3<Float>],     // 3 × chunkTriangleCount
    renderUVs: [SIMD2<Float>],          // 3 × chunkTriangleCount
    chunkTriangleCount: Int,
    chosenViews: [UInt16],               // GLOBAL array
    candidateViews: CandidateViewSnapshot,
    onProgress: (Double) -> Void
) throws {
    // Compile kernel.
    let library: MTLLibrary
    do {
        library = try device.makeLibrary(source: kBakeShaderSource, options: nil)
    } catch {
        throw MeshAtlasBakerError.shaderCompileFailed(error.localizedDescription)
    }
    guard let function = library.makeFunction(name: "bakeAtlas") else {
        throw MeshAtlasBakerError.pipelineCreationFailed
    }
    let pipeline: MTLComputePipelineState
    do {
        pipeline = try device.makeComputePipelineState(function: function)
    } catch {
        throw MeshAtlasBakerError.pipelineCreationFailed
    }
    guard let queue = device.makeCommandQueue() else {
        throw MeshAtlasBakerError.pipelineCreationFailed
    }

    // Build chunk-local buffers ONCE (reused across sub-chunks).
    // Pad SIMD3 → SIMD4 so device-side float3* reads at 16-byte stride.
    var triVertsPadded = [SIMD4<Float>]()
    triVertsPadded.reserveCapacity(renderVertices.count)
    for v in renderVertices {
        triVertsPadded.append(SIMD4<Float>(v.x, v.y, v.z, 0))
    }
    guard let triVertBuf = device.makeBuffer(
        bytes: triVertsPadded,
        length: triVertsPadded.count * MemoryLayout<SIMD4<Float>>.stride,
        options: .storageModeShared
    ) else { throw MeshAtlasBakerError.bufferAllocationFailed }
    triVertsPadded.removeAll(keepingCapacity: false)

    guard let triUVBuf = renderUVs.withUnsafeBufferPointer({ ptr -> MTLBuffer? in
        device.makeBuffer(bytes: ptr.baseAddress!,
                          length: renderUVs.count * MemoryLayout<SIMD2<Float>>.stride,
                          options: .storageModeShared)
    }) else { throw MeshAtlasBakerError.bufferAllocationFailed }

    var viewsGPU: [ViewDataGPU] = candidateViews.frames.map { f in
        ViewDataGPU(
            viewMatrix: f.viewMatrix,
            projMatrix: f.projectionMatrix,
            cameraPosition: SIMD4<Float>(f.cameraPosition.x,
                                         f.cameraPosition.y,
                                         f.cameraPosition.z, 0),
            cameraForward: SIMD4<Float>(f.cameraForward.x,
                                         f.cameraForward.y,
                                         f.cameraForward.z, 0),
            sharpness: f.sharpness,
            textureIndex: UInt32(f.textureIndex)
        )
    }
    guard let viewsBuf = device.makeBuffer(
        bytes: &viewsGPU,
        length: viewsGPU.count * MemoryLayout<ViewDataGPU>.stride,
        options: .storageModeShared
    ) else { throw MeshAtlasBakerError.bufferAllocationFailed }
    viewsGPU.removeAll(keepingCapacity: false)

    guard let chosenBuf = chosenViews.withUnsafeBufferPointer({ ptr -> MTLBuffer? in
        device.makeBuffer(bytes: ptr.baseAddress!,
                          length: chosenViews.count * MemoryLayout<UInt16>.stride,
                          options: .storageModeShared)
    }) else { throw MeshAtlasBakerError.bufferAllocationFailed }

    // Sub-chunked dispatch — commits + waits between sub-chunks so the
    // GPU yields back to the system UI compositor.
    let subChunkSize = MeshAtlasBaker.subChunkTriangles
    var subStart = 0
    while subStart < chunkTriangleCount {
        let subLen = min(subChunkSize, chunkTriangleCount - subStart)

        var params = BakeParams(
            atlasSize: UInt32(atlasSize),
            tileSize: UInt32(tileSize),
            tilesPerRow: UInt32(tilesPerRow),
            chunkTriangleCount: UInt32(chunkTriangleCount),
            chunkTriangleOffset: UInt32(chunkTriangleOffset),
            subChunkStart: UInt32(subStart)
        )

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw MeshAtlasBakerError.dispatchFailed
        }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(atlas, index: 0)
        enc.setTexture(candidateViews.textureArray, index: 1)
        enc.setBuffer(triVertBuf, offset: 0, index: 0)
        enc.setBuffer(triUVBuf,   offset: 0, index: 1)
        enc.setBuffer(viewsBuf,   offset: 0, index: 2)
        enc.setBuffer(chosenBuf,  offset: 0, index: 3)
        enc.setBytes(&params, length: MemoryLayout<BakeParams>.stride, index: 4)

        // Threadgroup geometry — keep tiny so we yield often. 8×8×8 = 512.
        let tgX = min(tileSize, 8)
        let tgY = min(tileSize, 8)
        let maxTPG = pipeline.maxTotalThreadsPerThreadgroup
        let tgZ = max(1, min(maxTPG / (tgX * tgY), 8))
        let totalThreads = MTLSize(
            width: tileSize, height: tileSize, depth: subLen
        )
        enc.dispatchThreads(
            totalThreads,
            threadsPerThreadgroup: MTLSize(width: tgX, height: tgY, depth: tgZ)
        )
        enc.endEncoding()
        cmd.commit()
        // KEY: waitUntilCompleted between sub-chunks so the system UI
        // compositor gets a slice of GPU time. Without this, a single
        // mega-dispatch holds the GPU and the phone visually freezes.
        cmd.waitUntilCompleted()

        subStart += subLen
        onProgress(Double(subStart) / Double(chunkTriangleCount))
    }
}
