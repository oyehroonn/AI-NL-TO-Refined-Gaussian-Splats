//
//  MeshAtlasBaker.swift
//  Phase 2 — per-face MVS-style baking. Lifts the explorer mesh from
//  per-anchor-single-photo (Phase 1) to a single global mesh + atlas
//  texture where every triangle samples its own best camera view.
//
//  Pipeline:
//   1. WELD — merge all per-anchor meshes into one global mesh by snapping
//      world-space vertex positions to a 1 cm grid. Triangles that span
//      anchor boundaries lose their seams. Per-vertex normals are
//      accumulated from triangle normals.
//   2. PACK — every triangle gets a fixed-size square tile in a 4096x4096
//      atlas; the triangle is laid out within the tile as
//          V0 = bottom-left, V1 = bottom-right, V2 = top-center
//      with a 1-pixel inset for filtering safety. Tiles are walked in
//      row-major order (`tilesPerRow = atlasSize / tileSize`).
//   3. BEST-VIEW — for every triangle, score each candidate view and
//      pick the winner. Score is the same product the live overlay uses
//      (facing × distance × sharpness) plus a frustum visibility test.
//      O(triangles × views) — done on CPU because at typical scan sizes
//      it's a few hundred ms, which we can run on a background actor
//      without paying for a Metal compute kernel.
//   4. BAKE — Metal compute kernel; one thread per atlas texel. Recovers
//      the texel's world-space position via barycentric inversion of the
//      tile UVs, projects through the chosen view's matrices, samples
//      the candidate texture array slice. Texels that fall outside any
//      view's frustum get neutral mid-grey.
//
//  Output: BakedMesh — render geometry (3 verts per triangle, sequential
//  indices), welded physics geometry (shared vertices), and the atlas
//  MTLTexture. MeshExplorerView builds one SCNNode from these.
//

import Foundation
import Metal
import SceneKit
import simd

// MARK: - Public types

struct BakedMesh {
    /// Render geometry — atlas-uv-bearing, no shared vertices. 3 entries
    /// per triangle, 0…3N-1 sequential indices. Used for visual rendering.
    let renderVertices: [SIMD3<Float>]
    let renderNormals: [SIMD3<Float>]
    let renderUVs: [SIMD2<Float>]
    let renderTriangleCount: Int

    /// Welded physics mesh — shared vertices, fewer of them. Cleaner for
    /// concavePolyhedron collision-shape construction.
    let physicsVertices: [SIMD3<Float>]
    let physicsTriangles: [SIMD3<UInt32>]

    /// World-space AABB. Drives the FirstPersonController's spawn point.
    let worldMin: SIMD3<Float>
    let worldMax: SIMD3<Float>

    /// The baked atlas. SceneKit accepts MTLTexture as material.contents
    /// directly (no copy through CGImage).
    let atlas: MTLTexture
    /// Atlas dimensions (square).
    let atlasSize: Int

    /// Telemetry — for the HUD or for tuning thresholds later.
    let stats: BakeStats
}

struct BakeStats {
    let triangleCount: Int
    let weldedVertexCount: Int
    let candidateViewCount: Int
    let trianglesWithView: Int      // ≥1 view chosen
    let trianglesWithoutView: Int   // sentinel
    let weldElapsed: TimeInterval
    let bestViewElapsed: TimeInterval
    let bakeElapsed: TimeInterval
    let totalElapsed: TimeInterval
}

enum MeshAtlasBakerError: Error {
    case noSnapshots
    case noCandidateViews
    case metalUnavailable
    case shaderCompileFailed(String)
    case pipelineCreationFailed
    case textureAllocationFailed
    case bufferAllocationFailed
    case dispatchFailed
}

// MARK: - Baker

enum MeshAtlasBaker {

    /// Atlas size — power of 2 for GPU friendliness. 4096 fits ~65k
    /// triangles at a 16-pixel-per-tile budget; bigger rooms can fall
    /// back to 8 px tiles via the `tileSize` parameter below.
    static let atlasSize: Int = 4096
    /// Pixels per triangle tile. 16 → 256x256 tiles per atlas → 65,536
    /// max triangles. Reduces to 8 if the room is bigger than that.
    static let preferredTileSize: Int = 16
    /// Hard cap on triangles. Decimation is a Phase-4 concern; for now we
    /// truncate to keep the bake bounded.
    static let maxTriangles: Int = 1 << 18  // 262,144 — comfortably above
                                            // any indoor scene.

    /// Run the full bake. Synchronous; intended to be called from a
    /// detached Task (typically with `Task.detached(priority: .userInitiated)`)
    /// so the main thread is free to render the baking-overlay UX.
    static func bake(
        snapshots: [TexturedMeshRenderer.ExplorerSnapshot],
        candidateViews: CandidateViewSnapshot
    ) throws -> BakedMesh {
        guard !snapshots.isEmpty else { throw MeshAtlasBakerError.noSnapshots }
        guard !candidateViews.frames.isEmpty else {
            throw MeshAtlasBakerError.noCandidateViews
        }
        let device = candidateViews.device

        let tStart = CFAbsoluteTimeGetCurrent()

        // ── 1. WELD ──────────────────────────────────────────────────
        let welded = WeldedMesh.from(snapshots: snapshots,
                                     maxTriangles: maxTriangles)
        let tWeld = CFAbsoluteTimeGetCurrent()

        // Pick a tile size that fits all triangles in one atlas.
        let triCount = welded.triangles.count
        let tileSize: Int = pickTileSize(forTriangleCount: triCount)

        // ── 2. PACK ──────────────────────────────────────────────────
        let layout = AtlasLayout(atlasSize: atlasSize,
                                 tileSize: tileSize,
                                 triangleCount: triCount)

        // Assemble the render mesh: 3 verts per triangle, with atlas UVs.
        var renderVerts = [SIMD3<Float>](); renderVerts.reserveCapacity(triCount * 3)
        var renderNormals = [SIMD3<Float>](); renderNormals.reserveCapacity(triCount * 3)
        var renderUVs = [SIMD2<Float>](); renderUVs.reserveCapacity(triCount * 3)
        // Per-triangle world-space vertices (for the GPU bake) and centroid
        // + face normal (for best-view).
        var triWorldV = [SIMD3<Float>](); triWorldV.reserveCapacity(triCount * 3)
        var triCentroid = [SIMD3<Float>](); triCentroid.reserveCapacity(triCount)
        var triNormal = [SIMD3<Float>](); triNormal.reserveCapacity(triCount)

        for t in 0..<triCount {
            let tri = welded.triangles[t]
            let v0 = welded.vertices[Int(tri.x)]
            let v1 = welded.vertices[Int(tri.y)]
            let v2 = welded.vertices[Int(tri.z)]
            let n0 = welded.normals[Int(tri.x)]
            let n1 = welded.normals[Int(tri.y)]
            let n2 = welded.normals[Int(tri.z)]

            renderVerts.append(v0); renderVerts.append(v1); renderVerts.append(v2)
            renderNormals.append(n0); renderNormals.append(n1); renderNormals.append(n2)
            renderUVs.append(layout.uv(triangle: t, vertex: 0))
            renderUVs.append(layout.uv(triangle: t, vertex: 1))
            renderUVs.append(layout.uv(triangle: t, vertex: 2))

            triWorldV.append(v0); triWorldV.append(v1); triWorldV.append(v2)

            let centroid = (v0 + v1 + v2) / 3.0
            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let raw = simd_cross(edge1, edge2)
            let len = simd_length(raw)
            let faceNormal: SIMD3<Float> =
                len > 1e-8 ? raw / len : SIMD3<Float>(0, 1, 0)
            triCentroid.append(centroid)
            triNormal.append(faceNormal)
        }

        // ── 3. BEST-VIEW SELECTION (CPU) ─────────────────────────────
        let chosenViews: [UInt16] = selectBestViews(
            triangleCount: triCount,
            centroid: triCentroid,
            normal: triNormal,
            views: candidateViews.frames
        )
        let tBest = CFAbsoluteTimeGetCurrent()

        // ── 4. ATLAS BAKE (Metal compute) ────────────────────────────
        guard let atlas = makeAtlasTexture(device: device, size: atlasSize) else {
            throw MeshAtlasBakerError.textureAllocationFailed
        }
        try bakeAtlasOnGPU(
            device: device,
            atlas: atlas,
            atlasSize: atlasSize,
            tileSize: tileSize,
            tilesPerRow: layout.tilesPerRow,
            renderVertices: triWorldV,
            renderUVs: renderUVs,
            triangleCount: triCount,
            chosenViews: chosenViews,
            candidateViews: candidateViews
        )
        let tBake = CFAbsoluteTimeGetCurrent()

        // Stats
        let withView = chosenViews.reduce(0) { $0 + ($1 == .max ? 0 : 1) }
        let stats = BakeStats(
            triangleCount: triCount,
            weldedVertexCount: welded.vertices.count,
            candidateViewCount: candidateViews.frames.count,
            trianglesWithView: withView,
            trianglesWithoutView: triCount - withView,
            weldElapsed: tWeld - tStart,
            bestViewElapsed: tBest - tWeld,
            bakeElapsed: tBake - tBest,
            totalElapsed: tBake - tStart
        )

        return BakedMesh(
            renderVertices: renderVerts,
            renderNormals: renderNormals,
            renderUVs: renderUVs,
            renderTriangleCount: triCount,
            physicsVertices: welded.vertices,
            physicsTriangles: welded.triangles,
            worldMin: welded.worldMin,
            worldMax: welded.worldMax,
            atlas: atlas,
            atlasSize: atlasSize,
            stats: stats
        )
    }

    // MARK: - Internal helpers

    private static func pickTileSize(forTriangleCount triCount: Int) -> Int {
        // tilesPerRow = atlasSize / tileSize; max triangles = tilesPerRow².
        // 16 px → 65,536; 8 px → 262,144; 4 px → 1,048,576.
        // Drop tile size as the room grows; never go below 4 px.
        if triCount <= 65_536 { return 16 }
        if triCount <= 262_144 { return 8 }
        return 4
    }

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

    /// Snap to a 1cm grid. ARKit anchor seams are at sub-mm precision but
    /// the cells are always >> 1cm so this resolves perfectly.
    static let cellSize: Float = 0.01

    static func from(
        snapshots: [TexturedMeshRenderer.ExplorerSnapshot],
        maxTriangles: Int
    ) -> WeldedMesh {
        var mesh = WeldedMesh()

        // Hash key = quantised (x, y, z) cell index. Int32 triple keeps
        // it cheap to hash and lookup.
        struct CellKey: Hashable { let x: Int32; let y: Int32; let z: Int32 }
        var hashToIndex: [CellKey: UInt32] = [:]
        // Reserve generously — typical room has 5K-50K welded vertices.
        hashToIndex.reserveCapacity(50_000)

        // Accumulate face normals into per-vertex sums; normalise at end.
        var normalAccum: [SIMD3<Float>] = []

        for snap in snapshots {
            // Pull out vertex positions in anchor-local space, transform to
            // world space.
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

            // local index → global index after welding.
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

            // Read triangles, rewrite indices, accumulate face normals.
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
                    if mesh.triangles.count >= maxTriangles { break }
                    let (a, b, c) = tri(at: t)
                    let g0 = localToGlobal[a]
                    let g1 = localToGlobal[b]
                    let g2 = localToGlobal[c]
                    // Skip triangles collapsed by welding.
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
            if mesh.triangles.count >= maxTriangles { break }
        }

        // Normalise vertex normals.
        mesh.normals = normalAccum.map { n in
            let len = simd_length(n)
            return len > 1e-6 ? n / len : SIMD3<Float>(0, 1, 0)
        }
        // Defensive: if no geometry survived, give a tiny AABB so the
        // explorer still has something to spawn into.
        if !mesh.worldMin.x.isFinite || !mesh.worldMax.x.isFinite {
            mesh.worldMin = SIMD3<Float>(-1, -1, -1)
            mesh.worldMax = SIMD3<Float>( 1,  1,  1)
        }
        return mesh
    }
}

// MARK: - Atlas layout

/// Maps triangle index → atlas tile UVs. Layout per tile (tileSize × tileSize):
///   V0 → (1, 1)                    bottom-left + 1 px inset
///   V1 → (tileSize-1, 1)           bottom-right - 1 px inset
///   V2 → (tileSize/2, tileSize-1)  top-center - 1 px inset
///
/// Inset gives bilinear filtering a clean 1-pixel margin so neighbouring
/// tiles never bleed into each other's triangles during sampling.
private struct AtlasLayout {
    let atlasSize: Int
    let tileSize: Int
    let tilesPerRow: Int
    let triangleCount: Int

    init(atlasSize: Int, tileSize: Int, triangleCount: Int) {
        self.atlasSize = atlasSize
        self.tileSize = tileSize
        self.tilesPerRow = atlasSize / tileSize
        self.triangleCount = triangleCount
    }

    func uv(triangle t: Int, vertex i: Int) -> SIMD2<Float> {
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
        case 2:
            pxCorner = SIMD2(Float(tileX * tileSize) + halfTile,
                             Float((tileY + 1) * tileSize) - inset)
        default:
            pxCorner = SIMD2(0, 0)
        }
        return pxCorner / Float(atlasSize)
    }
}

// MARK: - Best-view selection (CPU)

private func selectBestViews(
    triangleCount: Int,
    centroid: [SIMD3<Float>],
    normal: [SIMD3<Float>],
    views: [CandidateViewPool.Frame]
) -> [UInt16] {
    let viewCount = views.count
    var chosen = [UInt16](repeating: .max, count: triangleCount)

    // Pre-pull view fields into compact arrays for cache friendliness in
    // the hot inner loop.
    let camPos: [SIMD3<Float>] = views.map { $0.cameraPosition }
    let camFwd: [SIMD3<Float>] = views.map { $0.cameraForward }
    let viewMats: [simd_float4x4] = views.map { $0.viewMatrix }
    let projMats: [simd_float4x4] = views.map { $0.projectionMatrix }
    let sharps: [Float] = views.map { $0.sharpness }

    for t in 0..<triangleCount {
        let c = centroid[t]
        let n = normal[t]
        var bestScore: Float = 0.05  // floor — anything below is "no view"
        var bestIdx: Int = -1

        for v in 0..<viewCount {
            // Visibility: project centroid through view+proj.
            let mv = simd_mul(viewMats[v], SIMD4<Float>(c.x, c.y, c.z, 1))
            let clip = simd_mul(projMats[v], mv)
            if clip.w <= 0 { continue }
            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            // Stay inside the [-0.95, 0.95] inset to mirror the same
            // "tight" UV inset baked into the bake-time test.
            if abs(ndcX) > 0.95 || abs(ndcY) > 0.95 { continue }

            // Facing: face must point at the camera, not away.
            let toCamRaw = camPos[v] - c
            let dist = simd_length(toCamRaw)
            if dist < 0.05 { continue }
            let toCam = toCamRaw / dist
            let facing = simd_dot(n, toCam)
            if facing <= 0.10 { continue }

            // Score: same shape as the live overlay's score so the bake's
            // selections track the user's intuition about which photo
            // "looks best."
            let distScore: Float = min(1, 1.5 / max(dist, 0.3))
            let sharpScore: Float = min(1, max(0, sharps[v]))
            let score: Float = facing * distScore * sharpScore

            if score > bestScore {
                bestScore = score
                bestIdx = v
            }
        }
        if bestIdx >= 0 {
            chosen[t] = UInt16(bestIdx)
        }
    }
    return chosen
}

// MARK: - GPU bake

/// Push-constant struct passed to the bake kernel. Same layout as the
/// `BakeParams` struct declared in the Metal source below.
private struct BakeParams {
    var atlasSize: UInt32
    var tileSize: UInt32
    var tilesPerRow: UInt32
    var triangleCount: UInt32
}

/// One ViewData per candidate, packed for the kernel's `device const
/// ViewData*` buffer. Match the Metal layout EXACTLY (16-byte alignment
/// for matrices; pad floats to 16 bytes manually).
private struct ViewDataGPU {
    var viewMatrix: simd_float4x4
    var projMatrix: simd_float4x4
    var cameraPosition: SIMD4<Float>     // .xyz; .w padding
    var cameraForward: SIMD4<Float>      // .xyz; .w padding
    var sharpness: Float
    var textureIndex: UInt32
    var _pad0: Float = 0
    var _pad1: Float = 0
}

private let kBakeShaderSource: String = """
#include <metal_stdlib>
using namespace metal;

struct BakeParams {
    uint atlasSize;
    uint tileSize;
    uint tilesPerRow;
    uint triangleCount;
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

// One thread per (i, j, t):
//   - i, j ∈ [0, tileSize)  : pixel within the triangle's tile
//   - t    ∈ [0, triangleCount) : which triangle
//
// We write into atlas pixel (tileX*tileSize + i, tileY*tileSize + j) the
// colour sampled from the chosen view's slice in the candidate view
// texture array. Texels that fall outside the triangular region of the
// tile, or whose chosen view doesn't see them, get neutral mid-grey.
kernel void bakeAtlas(
    texture2d<float, access::write>           atlas      [[texture(0)]],
    texture2d_array<float, access::sample>    candidates [[texture(1)]],
    device   const float3*                    triVerts   [[buffer(0)]],
    device   const float2*                    triUVs     [[buffer(1)]],
    device   const ViewDataGPU*               views      [[buffer(2)]],
    device   const ushort*                    chosenView [[buffer(3)]],
    constant BakeParams&                      P          [[buffer(4)]],
    uint3                                     gid        [[thread_position_in_grid]]
) {
    if (gid.x >= P.tileSize || gid.y >= P.tileSize || gid.z >= P.triangleCount) return;

    uint t      = gid.z;
    uint tileX  = t % P.tilesPerRow;
    uint tileY  = t / P.tilesPerRow;
    uint pixelX = tileX * P.tileSize + gid.x;
    uint pixelY = tileY * P.tileSize + gid.y;

    // Atlas UV at texel center, [0, 1].
    float2 atlasUV = float2((float)pixelX + 0.5, (float)pixelY + 0.5)
                     / (float)P.atlasSize;

    // Triangle vertices + atlas UVs (3 entries per triangle, sequential).
    float3 V0 = triVerts[t * 3 + 0];
    float3 V1 = triVerts[t * 3 + 1];
    float3 V2 = triVerts[t * 3 + 2];
    float2 UV0 = triUVs[t * 3 + 0];
    float2 UV1 = triUVs[t * 3 + 1];
    float2 UV2 = triUVs[t * 3 + 2];

    // Barycentric of atlasUV in the (UV0, UV1, UV2) tile-triangle.
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

    // Outside the tile-triangle (with a tiny epsilon for filtering
    // safety). These texels are atlas waste; fill with grey so the
    // atlas is fully written and there's no garbage.
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

    // World-space position of this atlas texel.
    float3 worldPos = b0 * V0 + b1 * V1 + b2 * V2;

    // Chosen view for this triangle.
    ushort viewIdx = chosenView[t];
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

    // NDC → texture UV [0, 1] (image origin top-left, so flip Y).
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

private func bakeAtlasOnGPU(
    device: MTLDevice,
    atlas: MTLTexture,
    atlasSize: Int,
    tileSize: Int,
    tilesPerRow: Int,
    renderVertices: [SIMD3<Float>],     // 3 × triangleCount
    renderUVs: [SIMD2<Float>],          // 3 × triangleCount
    triangleCount: Int,
    chosenViews: [UInt16],
    candidateViews: CandidateViewSnapshot
) throws {
    // Compile the shader.
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

    guard let cmdQueue = device.makeCommandQueue() else {
        throw MeshAtlasBakerError.pipelineCreationFailed
    }

    // Pack triangle vertices into a tightly-packed float4 buffer (Metal's
    // float3 device alignment is 16 bytes per element — we pad to keep
    // layout deterministic).
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

    guard let triUVBuf = renderUVs.withUnsafeBufferPointer({ ptr -> MTLBuffer? in
        device.makeBuffer(bytes: ptr.baseAddress!,
                          length: renderUVs.count * MemoryLayout<SIMD2<Float>>.stride,
                          options: .storageModeShared)
    }) else { throw MeshAtlasBakerError.bufferAllocationFailed }

    // Pack views into ViewDataGPU. Source frame's textureIndex == slice
    // index in the candidate texture array.
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

    guard let chosenBuf = chosenViews.withUnsafeBufferPointer({ ptr -> MTLBuffer? in
        device.makeBuffer(bytes: ptr.baseAddress!,
                          length: chosenViews.count * MemoryLayout<UInt16>.stride,
                          options: .storageModeShared)
    }) else { throw MeshAtlasBakerError.bufferAllocationFailed }

    var params = BakeParams(
        atlasSize: UInt32(atlasSize),
        tileSize: UInt32(tileSize),
        tilesPerRow: UInt32(tilesPerRow),
        triangleCount: UInt32(triangleCount)
    )

    guard let cmd = cmdQueue.makeCommandBuffer(),
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

    // Threadgroup: pick a size that fits the tile in (x, y), and a small
    // z so we don't oversubscribe the GPU on tiny rooms.
    let maxThreadsPerGroup = pipeline.maxTotalThreadsPerThreadgroup
    let tgX = min(tileSize, 8)
    let tgY = min(tileSize, 8)
    let tgZ = max(1, min(maxThreadsPerGroup / (tgX * tgY), 8))
    let threadsPerGroup = MTLSize(width: tgX, height: tgY, depth: tgZ)
    let totalThreads = MTLSize(width: tileSize,
                                height: tileSize,
                                depth: triangleCount)
    enc.dispatchThreads(totalThreads, threadsPerThreadgroup: threadsPerGroup)
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
}
