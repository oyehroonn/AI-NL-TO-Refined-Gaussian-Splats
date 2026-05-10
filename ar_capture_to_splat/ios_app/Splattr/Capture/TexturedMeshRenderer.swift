//
//  TexturedMeshRenderer.swift
//  AR-Layer 2.5 — Gold tier: live mesh overlay textured with the camera
//  feed instead of the flat classification colors of MeshLiveRenderer.
//
//  As the user sweeps the room with the iPhone, ARKit's sceneReconstruction
//  emits ARMeshAnchors. For each new anchor we:
//    1. Snapshot the most recent camera frame as a UIImage (downsized).
//    2. Capture the camera's view+projection matrices at snapshot time.
//    3. Compute one (u, v) texture coordinate per mesh vertex by projecting
//       its world-space position through that snapshot camera.
//    4. Bake the snapshot UIImage as the SCNMaterial diffuse with those UVs.
//
//  The result: each chunk of the mesh shows the actual photo of that part
//  of the room as it was first seen — the "filling-in with real-world
//  appearance" effect users see in Polycam Free / Scaniverse.
//
//  This is NOT a Gaussian splat. It's a textured polygon mesh — the cheap
//  visual approximation that ships in the Gold tier (free).
//

import ARKit
import CoreImage
import SceneKit
import SwiftUI
import UIKit
import simd

@MainActor
final class TexturedMeshRenderer: NSObject, ObservableObject, ARSCNViewDelegate {

    @Published var isEnabled: Bool = true {
        didSet {
            for node in trackedNodes.values {
                node.opacity = isEnabled ? 1.0 : 0.0
            }
        }
    }

    @Published private(set) var anchorCount: Int = 0
    @Published private(set) var surfaceCoverage = SurfaceCoverageSummary()
    @Published private(set) var weakAreaHint: WeakAreaHint?
    @Published private(set) var explorerReadiness = ExplorerReadiness()

    /// Caller (CaptureView) attaches the running ARSession so we can pull
    /// the latest captured image + camera matrices in `willRenderScene`.
    func attach(session: ARSession) {
        self.arSession = session
    }

    func reset() {
        for node in trackedNodes.values {
            node.removeFromParentNode()
        }
        trackedNodes.removeAll()
        anchorsByID.removeAll()
        snapshotsByAnchor.removeAll()
        anchorCoverageByID.removeAll()
        anchorCentroidByID.removeAll()
        anchorBoundsByID.removeAll()
        anchorCount = 0
        surfaceCoverage = SurfaceCoverageSummary()
        weakAreaHint = nil
        explorerReadiness = ExplorerReadiness()
        latestSnapshot = nil
    }

    /// Free the per-anchor ring-buffer snapshots (~5 MB × anchor count =
    /// ~250 MB for a typical room) without touching geometry, the anchor
    /// dictionary, or the live SCN nodes.
    ///
    /// Currently retained for future memory-pressure handling. The G1
    /// explorer flow intentionally does NOT call this on Explore entry,
    /// because dropping the per-anchor candidate snapshots causes the
    /// next explore cycle to temporarily lose color until ARKit repopulates
    /// the buffers.
    ///
    /// Live overlay rebuilds itself naturally on the next willRenderScene
    /// + didUpdate cycle (typically <2 s). The user does not see a black
    /// frame because we don't drop the SCN node geometries — only the
    /// per-anchor ScoredSnapshot ring buffers and the latestSnapshot.
    func releaseLiveSnapshots() {
        snapshotsByAnchor.removeAll(keepingCapacity: false)
        latestSnapshot = nil
    }

    /// Captured anchor data the post-capture explorer needs to rebuild the
    /// mesh in its own SCNScene with collision physics.
    ///
    /// IMPORTANT: every byte buffer below is a DEEP COPY taken at snapshot
    /// time — never a reference to ARKit's live MTLBuffer. The AR session
    /// keeps mutating its mesh-anchor buffers (refinement) and may free
    /// them when an anchor is removed, which would corrupt or zero out a
    /// shared geometry. Owning the bytes guarantees the explorer scene can
    /// stay valid even while the AR session continues underneath.
    struct ExplorerSnapshot {
        struct BlendView {
            /// Per-vertex UVs (SIMD2<Float>) baked from one ranked camera view.
            let uvData: Data
            /// The source photo for this view, later color-balanced in the explorer.
            let textureImage: UIImage
            /// Raw quality weight for top-K blending. Higher = more trusted.
            let qualityScore: Float
        }

        let worldTransform: simd_float4x4
        /// Tightly-packed SIMD3<Float> vertex positions in anchor-local space.
        let vertexData: Data
        let vertexCount: Int
        /// Tightly-packed SIMD3<Float> normals (may be empty).
        let normalData: Data
        let normalCount: Int
        /// Triangle indices.
        let indexData: Data
        let triangleCount: Int
        let bytesPerIndex: Int
        /// World-space AABB of the vertices after applying worldTransform.
        let worldMin: SIMD3<Float>
        let worldMax: SIMD3<Float>
        /// Ranked per-anchor views used by the explorer's top-K blend path.
        let blendViews: [BlendView]
    }

    struct SurfaceCoverageSummary: Equatable {
        var wallFraction: Double = 0
        var floorFraction: Double = 0
        var ceilingFraction: Double = 0
        var wallCount: Int = 0
        var floorCount: Int = 0
        var ceilingCount: Int = 0

        var hasAnyData: Bool {
            wallCount > 0 || floorCount > 0 || ceilingCount > 0
        }
    }

    struct WeakAreaHint: Equatable {
        let label: String
        let normalizedX: CGFloat
        let normalizedY: CGFloat
        let isOnScreen: Bool
        let horizontalDirection: Int
        let verticalDirection: Int
        let dwellProgress: CGFloat
    }

    struct ExplorerReadiness: Equatable {
        static let requiredTexturedAnchorCount: Int = 10
        static let minimumCapturedVolumeCubicMeters: Float = 1.0

        var texturedAnchorCount: Int = 0
        var capturedVolumeCubicMeters: Float = 0

        var hasEnoughTexturedAnchors: Bool {
            texturedAnchorCount >= Self.requiredTexturedAnchorCount
        }

        var hasEnoughCapturedVolume: Bool {
            capturedVolumeCubicMeters >= Self.minimumCapturedVolumeCubicMeters
        }

        var isReady: Bool {
            hasEnoughTexturedAnchors && hasEnoughCapturedVolume
        }
    }

    struct RoomPlanObjectCoverage: Identifiable, Equatable {
        let id: UUID
        let label: String
        let coverageScore: Float
        let needsMoreCoverage: Bool
    }

    /// Snapshot of every currently-textured anchor for hand-off to the
    /// MeshExplorerView. Reads each anchor's raw Metal buffers and copies
    /// every byte into freshly-allocated `Data` so the resulting array is
    /// fully independent of ARKit's live state.
    ///
    /// Uses up to the top three scoring views per anchor. When the capture
    /// coordinator hands us a paused CandidateViewPool snapshot we rank
    /// those accepted-frame views first; otherwise we fall back to this
    /// renderer's live per-anchor ring buffer.
    func snapshotForExplorer(candidateViews: CandidateViewSnapshot? = nil) -> [ExplorerSnapshot] {
        var out: [ExplorerSnapshot] = []
        out.reserveCapacity(trackedNodes.count)
        for (id, anchor) in anchorsByID {
            if let candidateViews,
               let owned = ownGeometryFromAnchor(anchor: anchor, candidateViews: candidateViews) {
                out.append(owned)
                continue
            }
            let ranked = topSnapshots(forAnchorID: id, limit: 3)
            guard !ranked.isEmpty else { continue }
            guard let owned = ownGeometryFromAnchor(anchor: anchor, rankedSnapshots: ranked) else { continue }
            out.append(owned)
        }
        return out
    }

    /// Read the ARMeshAnchor's raw geometry buffers directly, copy bytes
    /// into freshly-allocated `Data`, recompute UVs for each retained
    /// ranked camera view, and bundle the explorer blend layers. The
    /// resulting snapshot shares no Metal buffer with ARKit.
    private func ownGeometryFromAnchor(
        anchor: ARMeshAnchor,
        rankedSnapshots: [ScoredSnapshot]
    ) -> ExplorerSnapshot? {
        let g = anchor.geometry
        let vertexCount = g.vertices.count
        guard vertexCount > 0 else { return nil }
        let xform = anchor.transform

        // ── Vertices: read from MTLBuffer.contents() and tight-pack ─────
        var verts = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        let vBase = g.vertices.buffer.contents().advanced(by: g.vertices.offset)
        for i in 0..<vertexCount {
            let p = vBase.advanced(by: i * g.vertices.stride)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            verts[i] = p
        }
        let vertexData = verts.withUnsafeBufferPointer { Data(buffer: $0) }

        // World-space AABB (used by the explorer to spawn the player).
        var wmin = SIMD3<Float>( .infinity,  .infinity,  .infinity)
        var wmax = SIMD3<Float>(-.infinity, -.infinity, -.infinity)
        for v in verts {
            let w4 = simd_mul(xform, SIMD4<Float>(v.x, v.y, v.z, 1))
            let w = SIMD3<Float>(w4.x, w4.y, w4.z)
            wmin = simd_min(wmin, w)
            wmax = simd_max(wmax, w)
        }

        // ── Normals (optional) ──────────────────────────────────────────
        var normalData = Data()
        var normalCount = 0
        if g.normals.count == vertexCount {
            var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
            let nBase = g.normals.buffer.contents().advanced(by: g.normals.offset)
            for i in 0..<vertexCount {
                let p = nBase.advanced(by: i * g.normals.stride)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                normals[i] = p
            }
            normalData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
            normalCount = vertexCount
        }

        let blendViews = rankedSnapshots.compactMap { scored -> ExplorerSnapshot.BlendView? in
            let projected = projectUVData(
                vertices: verts,
                worldTransform: xform,
                snapshot: scored.snapshot
            )
            guard projected.validVertexCount > 0 else { return nil }
            // Visibility/in-frustum validity should affect the layer's trust,
            // not just the raw view-angle and sharpness score.
            let visibility = Float(projected.validVertexCount) / Float(max(1, vertexCount))
            return ExplorerSnapshot.BlendView(
                uvData: projected.uvData,
                textureImage: scored.snapshot.image,
                qualityScore: max(0.0001, scored.score * visibility)
            )
        }
        guard !blendViews.isEmpty else { return nil }

        // ── Triangle indices: copy directly from the MTLBuffer ──────────
        let triangleCount = g.faces.count
        guard triangleCount > 0 else { return nil }
        let bytesPerIndex = g.faces.bytesPerIndex
        let totalIndexBytes = triangleCount * 3 * bytesPerIndex
        let iBase = g.faces.buffer.contents()
        let indexData = Data(bytes: iBase, count: totalIndexBytes)

        return ExplorerSnapshot(
            worldTransform: xform,
            vertexData: vertexData,
            vertexCount: vertexCount,
            normalData: normalData,
            normalCount: normalCount,
            indexData: indexData,
            triangleCount: triangleCount,
            bytesPerIndex: bytesPerIndex,
            worldMin: wmin,
            worldMax: wmax,
            blendViews: blendViews
        )
    }

    private func ownGeometryFromAnchor(
        anchor: ARMeshAnchor,
        candidateViews: CandidateViewSnapshot
    ) -> ExplorerSnapshot? {
        let g = anchor.geometry
        let vertexCount = g.vertices.count
        guard vertexCount > 0 else { return nil }
        let xform = anchor.transform

        var verts = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        let vBase = g.vertices.buffer.contents().advanced(by: g.vertices.offset)
        for i in 0..<vertexCount {
            let p = vBase.advanced(by: i * g.vertices.stride)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            verts[i] = p
        }
        let vertexData = verts.withUnsafeBufferPointer { Data(buffer: $0) }

        var wmin = SIMD3<Float>( .infinity,  .infinity,  .infinity)
        var wmax = SIMD3<Float>(-.infinity, -.infinity, -.infinity)
        for v in verts {
            let w4 = simd_mul(xform, SIMD4<Float>(v.x, v.y, v.z, 1))
            let w = SIMD3<Float>(w4.x, w4.y, w4.z)
            wmin = simd_min(wmin, w)
            wmax = simd_max(wmax, w)
        }

        var normalData = Data()
        var normalCount = 0
        if g.normals.count == vertexCount {
            var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
            let nBase = g.normals.buffer.contents().advanced(by: g.normals.offset)
            for i in 0..<vertexCount {
                let p = nBase.advanced(by: i * g.normals.stride)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                normals[i] = p
            }
            normalData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
            normalCount = vertexCount
        }

        let centroid = anchorCentroidByID[anchor.identifier] ?? computeCentroid(for: anchor)
        let rankedViews = topCandidateViews(
            anchorTransform: xform,
            anchorCentroid: centroid,
            vertices: verts,
            candidateViews: candidateViews,
            limit: 3
        )
        let blendViews = rankedViews.compactMap { ranked -> ExplorerSnapshot.BlendView? in
            guard let image = candidateViews.image(for: ranked.frame) else { return nil }
            return ExplorerSnapshot.BlendView(
                uvData: ranked.uvData,
                textureImage: image,
                qualityScore: ranked.qualityScore
            )
        }
        guard !blendViews.isEmpty else { return nil }

        let triangleCount = g.faces.count
        guard triangleCount > 0 else { return nil }
        let bytesPerIndex = g.faces.bytesPerIndex
        let totalIndexBytes = triangleCount * 3 * bytesPerIndex
        let iBase = g.faces.buffer.contents()
        let indexData = Data(bytes: iBase, count: totalIndexBytes)

        return ExplorerSnapshot(
            worldTransform: xform,
            vertexData: vertexData,
            vertexCount: vertexCount,
            normalData: normalData,
            normalCount: normalCount,
            indexData: indexData,
            triangleCount: triangleCount,
            bytesPerIndex: bytesPerIndex,
            worldMin: wmin,
            worldMax: wmax,
            blendViews: blendViews
        )
    }

    private func projectUVData(
        vertices: [SIMD3<Float>],
        worldTransform: simd_float4x4,
        snapshot: CameraSnapshot
    ) -> (uvData: Data, validVertexCount: Int) {
        projectUVData(
            vertices: vertices,
            worldTransform: worldTransform,
            viewMatrix: snapshot.viewMatrix,
            projectionMatrix: snapshot.projectionMatrix
        )
    }

    private func projectUVData(
        vertices: [SIMD3<Float>],
        worldTransform: simd_float4x4,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4
    ) -> (uvData: Data, validVertexCount: Int) {
        let viewProj = simd_mul(projectionMatrix, viewMatrix)
        let sentinel = SIMD2<Float>(-1, -1)
        var validVertexCount = 0
        var uvs = [SIMD2<Float>](repeating: sentinel, count: vertices.count)
        for i in 0..<vertices.count {
            let p = vertices[i]
            let world = simd_mul(worldTransform, SIMD4<Float>(p.x, p.y, p.z, 1))
            let clip = simd_mul(viewProj, world)
            if clip.w <= 0 { continue }
            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            let u: Float = Float((ndcX * 0.5) + 0.5)
            let v: Float = Float(1.0 - ((ndcY * 0.5) + 0.5))
            if u < 0.05 || u > 0.95 || v < 0.05 || v > 0.95 { continue }
            uvs[i] = SIMD2(u, v)
            validVertexCount += 1
        }
        let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        return (uvData, validVertexCount)
    }

    // MARK: - Internal state

    private weak var arSession: ARSession?
    private var trackedNodes: [UUID: SCNNode] = [:]
    /// Strong references to the live ARMeshAnchors so we can read their raw
    /// geometry buffers on demand (snapshotForExplorer). Without this, the
    /// only path to vertex/index bytes is through SCNGeometrySource.data,
    /// which is empty for MTLBuffer-based sources.
    private var anchorsByID: [UUID: ARMeshAnchor] = [:]
    private var latestSnapshot: CameraSnapshot?
    private var anchorCoverageByID: [UUID: AnchorCoverageState] = [:]
    private var anchorBoundsByID: [UUID: (min: SIMD3<Float>, max: SIMD3<Float>)] = [:]
    private var activeWeakTargetID: UUID?
    private var activeWeakTargetLockedAt: TimeInterval = 0
    private var activeWeakTargetVisibleSince: TimeInterval?
    /// Per-anchor ring buffer of best-scoring candidate snapshots. Each
    /// anchor keeps up to `maxSnapshotsPerAnchor` photos, ranked by
    /// `score(snapshot, anchor)`. The renderer always bakes the
    /// **highest-scoring** candidate, so an anchor's texture moves toward
    /// the photo where the camera was actually pointed at it from a good
    /// distance with a sharp shutter. Replaces the legacy "freeze the
    /// first-sighting snapshot forever" approach which gave us long
    /// horizontal smears and ceiling pixels on walls.
    private var snapshotsByAnchor: [UUID: [ScoredSnapshot]] = [:]

    /// Cached world-space centroid per anchor — the rough "where is this
    /// chunk of mesh in the room" point that scoring uses. Cheaper than
    /// recomputing it from anchor.geometry.vertices on every snapshot
    /// pump (~10 Hz × N anchors × M vertices ≈ a few μs but adds up).
    /// Refreshed on every didAdd / didUpdate.
    private var anchorCentroidByID: [UUID: SIMD3<Float>] = [:]
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Texture target side length. 512 is plenty for the hand-held overlay
    /// and keeps GPU memory bounded across many anchors.
    private let textureMaxDimension: CGFloat = 512
    private let weakAreaStickyDuration: TimeInterval = 1.2
    private let weakAreaHoldDuration: TimeInterval = 3.0

    private struct CameraSnapshot {
        let image: UIImage
        let viewMatrix: simd_float4x4         // world → camera (ARKit landscape)
        let projectionMatrix: simd_float4x4   // camera → NDC
        /// World-space camera origin. Cached on the snapshot so scoring it
        /// against an anchor doesn't have to invert viewMatrix every time.
        let cameraPosition: SIMD3<Float>
        /// World-space camera forward (the -Z axis of the ARKit camera).
        let cameraForward: SIMD3<Float>
        /// Sharpness in [0, 1]. Derived from BlurDetector's Laplacian
        /// variance and clipped to [0, 1] so it can be folded into a score
        /// product directly.
        let sharpness: Float
        /// Wall-clock timestamp the snapshot was captured at, for debugging
        /// and for tie-breaking between candidate snapshots with similar
        /// scores (prefer the more recent one — captures latest exposure).
        let timestamp: TimeInterval
    }

    /// A snapshot bundled with its score against ONE specific anchor.
    /// Stored in `snapshotsByAnchor` so we can rank candidates and pick the
    /// best one without recomputing scores every frame.
    private struct ScoredSnapshot {
        let snapshot: CameraSnapshot
        var score: Float
    }

    private enum AnchorCoverageBucket {
        case low
        case medium
        case high
    }

    private struct AnchorCoverageState {
        let centroid: SIMD3<Float>
        let classification: ARMeshClassification
        let bestScore: Float
        let candidateCount: Int
        let coverageScore: Float
        let bucket: AnchorCoverageBucket
    }

    /// How many candidate snapshots we keep per anchor. 5 is enough to
    /// cover the typical "user walks past, looks at it briefly from a few
    /// angles" pattern and bounds memory at ~5 × textureMaxDimension² ×
    /// 4 bytes per anchor (~5 MB for 50 anchors at 512px).
    private let maxSnapshotsPerAnchor: Int = 5

    // MARK: - SCNSceneRendererDelegate

    /// Sample the live frame on every render tick. Cheap on Apple silicon —
    /// CIImage→CGImage stays GPU-resident. Throttle to ~10 Hz to keep
    /// the hot path light.
    nonisolated func renderer(
        _ renderer: SCNSceneRenderer,
        willRenderScene scene: SCNScene,
        atTime time: TimeInterval
    ) {
        Task { @MainActor [weak self] in
            self?.updateLatestSnapshotThrottled(now: time)
        }
    }

    // MARK: - ARSCNViewDelegate (ARMeshAnchor lifecycle)

    nonisolated func renderer(
        _ renderer: SCNSceneRenderer,
        didAdd node: SCNNode,
        for anchor: ARAnchor
    ) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        Task { @MainActor [weak self] in
            self?.installTexturedMesh(into: node, from: mesh, isNew: true)
        }
    }

    nonisolated func renderer(
        _ renderer: SCNSceneRenderer,
        didUpdate node: SCNNode,
        for anchor: ARAnchor
    ) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        Task { @MainActor [weak self] in
            // ARKit refines the anchor as the user explores. We re-pick the
            // best-scoring snapshot from the per-anchor ring buffer (the
            // centroid may have drifted, so the previously-best photo
            // could no longer be best). Re-baking the texture from the new
            // best lets each anchor settle on the photo where the camera
            // was actually pointed at it.
            self?.installTexturedMesh(into: node, from: mesh, isNew: false)
        }
    }

    nonisolated func renderer(
        _ renderer: SCNSceneRenderer,
        didRemove node: SCNNode,
        for anchor: ARAnchor
    ) {
        let id = anchor.identifier
        Task { @MainActor [weak self] in
            self?.trackedNodes.removeValue(forKey: id)
            self?.anchorsByID.removeValue(forKey: id)
            self?.snapshotsByAnchor.removeValue(forKey: id)
            self?.anchorCoverageByID.removeValue(forKey: id)
            self?.anchorCentroidByID.removeValue(forKey: id)
            self?.anchorBoundsByID.removeValue(forKey: id)
            self?.anchorCount = self?.trackedNodes.count ?? 0
            self?.refreshCoverageTelemetry()
        }
    }

    // MARK: - Snapshot pump

    private var lastSnapshotAt: TimeInterval = 0

    private func updateLatestSnapshotThrottled(now: TimeInterval) {
        // 10 Hz is plenty — anchors are added far less often.
        if now - lastSnapshotAt < 0.1 { return }
        lastSnapshotAt = now
        guard let frame = arSession?.currentFrame else { return }
        guard let snap = makeSnapshot(from: frame) else { return }
        latestSnapshot = snap

        // P1.5 — every fresh snapshot is a candidate for EVERY tracked
        // anchor, not just the one ARKit happens to refine next. Score it
        // against each anchor's cached centroid and let the per-anchor
        // ring buffer decide whether to keep it. ~50 anchors × O(1) work
        // each at 10 Hz = ~500 cheap evaluations/sec — negligible.
        for (id, _) in anchorCentroidByID {
            consider(snapshot: snap, forAnchorID: id)
        }
        refreshCoverageTelemetry()
    }

    // MARK: - Scoring

    /// Compute world-space centroid of an anchor by averaging its vertex
    /// positions. ARKit hands us anchor-local coordinates, so we transform
    /// the mean by anchor.transform to land in world space.
    private func computeCentroid(for anchor: ARMeshAnchor) -> SIMD3<Float> {
        let g = anchor.geometry
        let n = g.vertices.count
        guard n > 0 else {
            // Fall back to the anchor's translation (origin in local space).
            let t = anchor.transform
            return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }
        let base = g.vertices.buffer.contents().advanced(by: g.vertices.offset)
        var sum = SIMD3<Float>(0, 0, 0)
        // Sample stride: for big anchors we don't need to read every vertex.
        // Cap at 256 samples — plenty for a stable centroid.
        let step = max(1, n / 256)
        var count = 0
        var i = 0
        while i < n {
            let p = base.advanced(by: i * g.vertices.stride)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            sum += p
            count += 1
            i += step
        }
        let local = sum / Float(count)
        let world4 = simd_mul(anchor.transform,
                              SIMD4<Float>(local.x, local.y, local.z, 1))
        return SIMD3<Float>(world4.x, world4.y, world4.z)
    }

    /// Approximate world-space bounds for one anchor by sampling up to 512
    /// vertices. Good enough for the Explore readiness gate and much cheaper
    /// than walking every vertex on every refresh.
    private func computeWorldBounds(for anchor: ARMeshAnchor) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let g = anchor.geometry
        let n = g.vertices.count
        let transform = anchor.transform
        guard n > 0 else {
            let t = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            return (t, t)
        }

        let base = g.vertices.buffer.contents().advanced(by: g.vertices.offset)
        let step = max(1, n / 512)
        var minBound = SIMD3<Float>(.infinity, .infinity, .infinity)
        var maxBound = SIMD3<Float>(-.infinity, -.infinity, -.infinity)
        var i = 0
        while i < n {
            let local = base.advanced(by: i * g.vertices.stride)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let world4 = simd_mul(transform, SIMD4<Float>(local.x, local.y, local.z, 1))
            let world = SIMD3<Float>(world4.x, world4.y, world4.z)
            minBound = simd_min(minBound, world)
            maxBound = simd_max(maxBound, world)
            i += step
        }

        if !minBound.x.isFinite || !maxBound.x.isFinite {
            let t = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            return (t, t)
        }
        return (minBound, maxBound)
    }

    /// Score a snapshot's suitability as the texture for an anchor.
    ///
    /// The product of three factors, each in [0, 1]:
    ///  - **view-angle**: cosine of the angle between camera forward and
    ///    direction-to-anchor. 1.0 = camera pointed straight at anchor,
    ///    0.0 = perpendicular or behind. We clamp to 0 below; a camera
    ///    facing AWAY from the anchor must never win the slot.
    ///  - **distance**: 1.0 at <0.5 m, falling off as 1/d. Closer photos
    ///    have higher pixel density per face → sharper texture.
    ///  - **sharpness**: BlurDetector value normalised to [0, 1]. A motion-
    ///    blurred frame can never beat a sharp one.
    ///
    /// All three must be reasonable; one weak factor zeros the score.
    private func score(
        snapshot snap: CameraSnapshot,
        anchorCentroid centroid: SIMD3<Float>
    ) -> Float {
        score(
            cameraPosition: snap.cameraPosition,
            cameraForward: snap.cameraForward,
            sharpness: snap.sharpness,
            anchorCentroid: centroid
        )
    }

    private func score(
        cameraPosition: SIMD3<Float>,
        cameraForward: SIMD3<Float>,
        sharpness: Float,
        anchorCentroid centroid: SIMD3<Float>
    ) -> Float {
        let toAnchor = centroid - cameraPosition
        let dist = simd_length(toAnchor)
        if dist < 1e-3 { return 0 }
        let dir = toAnchor / dist
        let dot = simd_dot(cameraForward, dir)
        let viewScore: Float = max(0, dot)              // [0, 1]
        let distScore: Float = min(1, 2.0 / max(dist, 0.5))  // 1 at <0.5m
        let sharpScore: Float = min(1, max(0, sharpness))
        return viewScore * distScore * sharpScore
    }

    /// Consider a snapshot as a candidate for an anchor: score it, insert
    /// into the ring buffer if it beats the worst slot or if there's room.
    private func consider(snapshot snap: CameraSnapshot, forAnchorID id: UUID) {
        guard let centroid = anchorCentroidByID[id] else { return }
        let s = score(snapshot: snap, anchorCentroid: centroid)
        // A score of 0 means the camera was looking AWAY from this anchor.
        // Don't pollute the ring buffer with these.
        if s <= 0.001 { return }

        var buf = snapshotsByAnchor[id] ?? []
        if buf.count < maxSnapshotsPerAnchor {
            buf.append(ScoredSnapshot(snapshot: snap, score: s))
        } else {
            // Find the worst slot; replace if the new score wins.
            var worstIdx = 0
            var worstScore: Float = buf[0].score
            for k in 1..<buf.count {
                if buf[k].score < worstScore {
                    worstScore = buf[k].score
                    worstIdx = k
                }
            }
            if s > worstScore {
                buf[worstIdx] = ScoredSnapshot(snapshot: snap, score: s)
            }
        }
        snapshotsByAnchor[id] = buf
    }

    /// Pick the best (highest-scoring) snapshot from the ring buffer.
    private func bestSnapshot(forAnchorID id: UUID) -> CameraSnapshot? {
        guard let buf = snapshotsByAnchor[id], !buf.isEmpty else { return nil }
        var best = buf[0]
        for k in 1..<buf.count where buf[k].score > best.score {
            best = buf[k]
        }
        return best.snapshot
    }

    private func topSnapshots(forAnchorID id: UUID, limit: Int) -> [ScoredSnapshot] {
        guard let buf = snapshotsByAnchor[id], !buf.isEmpty else { return [] }
        return buf
            .filter { $0.score > 0.001 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.snapshot.timestamp > rhs.snapshot.timestamp
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private struct RankedCandidateView {
        let frame: CandidateViewPool.Frame
        let uvData: Data
        let qualityScore: Float
    }

    private func topCandidateViews(
        anchorTransform: simd_float4x4,
        anchorCentroid centroid: SIMD3<Float>,
        vertices: [SIMD3<Float>],
        candidateViews: CandidateViewSnapshot,
        limit: Int
    ) -> [RankedCandidateView] {
        candidateViews.frames.compactMap { frame in
            let projected = projectUVData(
                vertices: vertices,
                worldTransform: anchorTransform,
                viewMatrix: frame.viewMatrix,
                projectionMatrix: frame.projectionMatrix
            )
            guard projected.validVertexCount > 0 else { return nil }
            let visibility = Float(projected.validVertexCount) / Float(max(1, vertices.count))
            let baseScore = score(
                cameraPosition: frame.cameraPosition,
                cameraForward: frame.cameraForward,
                sharpness: frame.sharpness,
                anchorCentroid: centroid
            )
            let qualityScore = max(0.0001, baseScore * visibility)
            guard qualityScore > 0.001 else { return nil }
            return RankedCandidateView(
                frame: frame,
                uvData: projected.uvData,
                qualityScore: qualityScore
            )
        }
        .sorted { lhs, rhs in
            if lhs.qualityScore == rhs.qualityScore {
                return lhs.frame.timestamp > rhs.frame.timestamp
            }
            return lhs.qualityScore > rhs.qualityScore
        }
        .prefix(limit)
        .map { $0 }
    }

    private func makeSnapshot(from frame: ARFrame) -> CameraSnapshot? {
        // Sharpness FIRST, against the full-resolution pixel buffer —
        // BlurDetector is internally tolerant to resolution but a full
        // luma plane gives a more reliable Laplacian variance.
        let sharpRaw = BlurDetector.score(for: frame.capturedImage)
        // Empirical normalisation: <30 = very blurry, 30-60 = motion blur,
        // 60-120 = ok, >120 = sharp. Map [0, 200] → [0, 1] linearly and
        // clip. This puts most "good" frames in [0.5, 1.0] and motion-
        // blurred frames in [0.0, 0.3], which is the dynamic range we
        // want when multiplying scores together.
        let sharpness: Float = Float(min(1.0, max(0.0, sharpRaw / 200.0)))

        // Downsize the captured pixel buffer to keep memory bounded.
        var ci = CIImage(cvPixelBuffer: frame.capturedImage)
        let originalExtent = ci.extent
        let scale = textureMaxDimension /
                    max(originalExtent.width, originalExtent.height)
        if scale < 1.0 {
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else {
            return nil
        }
        let image = UIImage(cgImage: cg)

        // ARKit camera matrices for landscape sensor orientation. We use
        // landscapeRight (the natural ARKit pixel-buffer orientation) so
        // matrices align with the un-rotated image we just baked.
        let viewSize = CGSize(width: image.size.width, height: image.size.height)
        let proj = frame.camera.projectionMatrix(
            for: .landscapeRight,
            viewportSize: viewSize,
            zNear: 0.05,
            zFar: 50.0
        )
        let view = frame.camera.viewMatrix(for: .landscapeRight)

        // World-space camera pose for scoring. The raw ARKit camera
        // transform is orientation-independent (the iPhone's camera in
        // world space) — use it rather than inverting the landscape view
        // matrix, which would re-introduce orientation rotation.
        let camWorld = frame.camera.transform
        let camPos = SIMD3<Float>(camWorld.columns.3.x,
                                  camWorld.columns.3.y,
                                  camWorld.columns.3.z)
        // ARKit cameras look down -Z in their local frame; world forward
        // is the negated z-axis column of the camera world transform.
        let camFwd = simd_normalize(SIMD3<Float>(-camWorld.columns.2.x,
                                                 -camWorld.columns.2.y,
                                                 -camWorld.columns.2.z))

        return CameraSnapshot(
            image: image,
            viewMatrix: view,
            projectionMatrix: proj,
            cameraPosition: camPos,
            cameraForward: camFwd,
            sharpness: sharpness,
            timestamp: frame.timestamp
        )
    }

    // MARK: - Build / refresh node geometry

    private func installTexturedMesh(
        into node: SCNNode,
        from anchor: ARMeshAnchor,
        isNew: Bool
    ) {
        let id = anchor.identifier

        // Refresh the centroid cache. Mesh anchors refine over time so the
        // centroid drifts; recomputing it here keeps the score function
        // honest, and rescoring stale ring-buffer entries against the new
        // centroid keeps "best-view" pointing at the latest geometry.
        let centroid = computeCentroid(for: anchor)
        anchorCentroidByID[id] = centroid
        anchorBoundsByID[id] = computeWorldBounds(for: anchor)

        // Re-score every ring-buffer entry against the (possibly-shifted)
        // centroid. Cheap — at most maxSnapshotsPerAnchor entries.
        if var buf = snapshotsByAnchor[id] {
            for k in 0..<buf.count {
                buf[k].score = score(snapshot: buf[k].snapshot,
                                     anchorCentroid: centroid)
            }
            snapshotsByAnchor[id] = buf
        }

        // Seed: if the buffer is empty and we have a latestSnapshot, give
        // this anchor at least ONE candidate so it shows something on the
        // very first didAdd (before the snapshot pump has had a chance to
        // re-iterate over the new anchor).
        if (snapshotsByAnchor[id]?.isEmpty ?? true), let latest = latestSnapshot {
            consider(snapshot: latest, forAnchorID: id)
        }

        // Pick the highest-scoring candidate and bake it.
        let coverageState = anchorCoverageByID[id]
        if let snap = bestSnapshot(forAnchorID: id),
           let geom = makeTexturedGeometry(from: anchor, snapshot: snap) {
            let material = makeTexturedMaterial(
                image: snap.image,
                coverageScore: coverageState?.coverageScore ?? 0,
                bucket: coverageState?.bucket ?? .low
            )
            geom.materials = [material]
            node.geometry = geom
        } else {
            // No snapshot yet (first second of capture before the pump has
            // fired). Show the translucent teal fallback so the user sees
            // something; the next didUpdate will retro-fit a real texture.
            let geom = makeFlatGeometry(from: anchor)
            geom.materials = [makeFlatMaterial(bucket: coverageState?.bucket ?? .low)]
            node.geometry = geom
        }

        node.opacity = isEnabled ? 1.0 : 0.0
        if isNew || trackedNodes[id] == nil {
            trackedNodes[id] = node
            anchorCount = trackedNodes.count
        }
        // Always refresh the anchor pointer; ARKit hands us the same anchor
        // object across didAdd/didUpdate, but we want our reference to track
        // the latest geometry generation regardless.
        anchorsByID[id] = anchor
        refreshCoverageTelemetry()
    }

    /// Build SCNGeometry with vertex positions, normals, and **per-vertex
    /// texture coordinates** computed by projecting each world-space vertex
    /// through the snapshot camera. Returns nil if the projection produced
    /// no valid UVs (e.g. snapshot pose data was malformed).
    private func makeTexturedGeometry(
        from anchor: ARMeshAnchor,
        snapshot: CameraSnapshot
    ) -> SCNGeometry? {
        let g = anchor.geometry
        let vertCount = g.vertices.count
        guard vertCount > 0 else { return nil }

        // Vertex source — share the Metal buffer with ARKit, no copy.
        let vertSource = SCNGeometrySource(
            buffer: g.vertices.buffer,
            vertexFormat: .float3,
            semantic: .vertex,
            vertexCount: vertCount,
            dataOffset: g.vertices.offset,
            dataStride: g.vertices.stride
        )

        // Normal source (when present).
        var sources: [SCNGeometrySource] = [vertSource]
        if g.normals.count == vertCount {
            sources.append(SCNGeometrySource(
                buffer: g.normals.buffer,
                vertexFormat: .float3,
                semantic: .normal,
                vertexCount: g.normals.count,
                dataOffset: g.normals.offset,
                dataStride: g.normals.stride
            ))
        }

        // UV source — computed per vertex by projecting through the snapshot.
        // Vertices that project outside a [0.05, 0.95] inset of the texture
        // are tagged with sentinel UV (-1, -1). The Phase 0 fragment shader
        // modifier on the explorer material catches that range and replaces
        // the fragment with neutral grey, so vertices that fell outside the
        // photo's frustum (or behind the camera) read as "missing" instead
        // of streaking the texture's edge pixels across the wall.
        let anchorXform = anchor.transform
        let viewProj = simd_mul(snapshot.projectionMatrix, snapshot.viewMatrix)
        let sentinel = SIMD2<Float>(-1, -1)
        var uvs = [SIMD2<Float>](repeating: sentinel, count: vertCount)
        // Read the vertex buffer host-side. Apple's mesh anchors use shared
        // memory, so .contents() reads back without a Metal blit.
        let vBase = g.vertices.buffer.contents().advanced(by: g.vertices.offset)
        for i in 0..<vertCount {
            let vp = vBase.advanced(by: i * g.vertices.stride)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let world = simd_mul(anchorXform, SIMD4<Float>(vp.x, vp.y, vp.z, 1.0))
            let clip = simd_mul(viewProj, world)
            // Behind-the-camera vertices (clip.w ≤ 0) are unrenderable from
            // this snapshot — sentinel them.
            if clip.w <= 0 { continue }
            // Perspective divide → NDC [-1, 1]
            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            // NDC → texture UV [0, 1]. ARKit's projectionMatrix uses GL-style
            // NDC where y points up; UIImage texture origin is top-left, so
            // flip y on the way in.
            let u: Float = Float((ndcX * 0.5) + 0.5)
            let v: Float = Float(1.0 - ((ndcY * 0.5) + 0.5))
            // Tight inset: vertices in [0, 0.05) ∪ (0.95, 1] still read
            // edge pixels, which smear visually. Sentinel them too.
            if u < 0.05 || u > 0.95 || v < 0.05 || v > 0.95 { continue }
            uvs[i] = SIMD2(u, v)
        }

        let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvSource = SCNGeometrySource(
            data: uvData,
            semantic: .texcoord,
            vectorCount: vertCount,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )
        sources.append(uvSource)

        // Faces — triangles directly from ARKit's index buffer.
        let element = SCNGeometryElement(
            buffer: g.faces.buffer,
            primitiveType: .triangles,
            primitiveCount: g.faces.count,
            bytesPerIndex: g.faces.bytesPerIndex
        )

        return SCNGeometry(sources: sources, elements: [element])
    }

    /// Fallback geometry without UVs — used until the first snapshot
    /// arrives, or if UV computation failed for some reason.
    private func makeFlatGeometry(from anchor: ARMeshAnchor) -> SCNGeometry {
        let g = anchor.geometry
        var sources: [SCNGeometrySource] = [
            SCNGeometrySource(
                buffer: g.vertices.buffer,
                vertexFormat: .float3,
                semantic: .vertex,
                vertexCount: g.vertices.count,
                dataOffset: g.vertices.offset,
                dataStride: g.vertices.stride
            )
        ]
        if g.normals.count == g.vertices.count {
            sources.append(SCNGeometrySource(
                buffer: g.normals.buffer,
                vertexFormat: .float3,
                semantic: .normal,
                vertexCount: g.normals.count,
                dataOffset: g.normals.offset,
                dataStride: g.normals.stride
            ))
        }
        let element = SCNGeometryElement(
            buffer: g.faces.buffer,
            primitiveType: .triangles,
            primitiveCount: g.faces.count,
            bytesPerIndex: g.faces.bytesPerIndex
        )
        return SCNGeometry(sources: sources, elements: [element])
    }

    private func makeTexturedMaterial(
        image: UIImage,
        coverageScore: Float = 0,
        bucket: AnchorCoverageBucket = .low
    ) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        // Slight transparency so the AR passthrough still shows through and
        // the mesh feels like an overlay rather than a hard occluder.
        m.transparency = 0.85
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        applyCoverageTint(
            to: m,
            coverageScore: coverageScore,
            bucket: bucket
        )
        return m
    }

    private func makeFlatMaterial(bucket: AnchorCoverageBucket = .low) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.30)
        m.transparency = 0.30
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        applyCoverageTint(
            to: m,
            coverageScore: 0,
            bucket: bucket
        )
        return m
    }

    private func refreshCoverageTelemetry() {
        var nextStates: [UUID: AnchorCoverageState] = [:]
        nextStates.reserveCapacity(anchorsByID.count)

        for (id, anchor) in anchorsByID {
            let centroid = anchorCentroidByID[id] ?? computeCentroid(for: anchor)
            let classification = Self.dominantClass(of: anchor)
            let buf = snapshotsByAnchor[id] ?? []
            let bestScore = buf.map(\.score).max() ?? 0
            let candidateCount = buf.count
            let candidateFactor = min(1.0, Float(candidateCount) / 3.0)
            let classFactor = Self.classificationConfidence(for: classification)
            let coverageScore = bestScore * candidateFactor * classFactor
            let bucket: AnchorCoverageBucket
            switch coverageScore {
            case ..<0.30:
                bucket = .low
            case ..<0.70:
                bucket = .medium
            default:
                bucket = .high
            }

            nextStates[id] = AnchorCoverageState(
                centroid: centroid,
                classification: classification,
                bestScore: bestScore,
                candidateCount: candidateCount,
                coverageScore: coverageScore,
                bucket: bucket
            )
        }

        anchorCoverageByID = nextStates
        surfaceCoverage = SurfaceCoverageSummary(
            wallFraction: averageCoverage(for: .wall, in: nextStates),
            floorFraction: averageCoverage(for: .floor, in: nextStates),
            ceilingFraction: averageCoverage(for: .ceiling, in: nextStates),
            wallCount: count(of: .wall, in: nextStates),
            floorCount: count(of: .floor, in: nextStates),
            ceilingCount: count(of: .ceiling, in: nextStates)
        )
        weakAreaHint = makeWeakAreaHint(from: nextStates)
        explorerReadiness = makeExplorerReadiness(from: nextStates)
        refreshLiveNodeTints(using: nextStates)
    }

    private func makeExplorerReadiness(
        from states: [UUID: AnchorCoverageState]
    ) -> ExplorerReadiness {
        let texturedAnchorCount = states.values.filter { $0.candidateCount > 0 && $0.bestScore > 0.001 }.count

        var minBound = SIMD3<Float>(.infinity, .infinity, .infinity)
        var maxBound = SIMD3<Float>(-.infinity, -.infinity, -.infinity)
        for bounds in anchorBoundsByID.values {
            minBound = simd_min(minBound, bounds.min)
            maxBound = simd_max(maxBound, bounds.max)
        }

        let volume: Float
        if minBound.x.isFinite && maxBound.x.isFinite {
            let extent = simd_max(maxBound - minBound, SIMD3<Float>(repeating: 0))
            volume = extent.x * extent.y * extent.z
        } else {
            volume = 0
        }

        return ExplorerReadiness(
            texturedAnchorCount: texturedAnchorCount,
            capturedVolumeCubicMeters: volume
        )
    }

    private func refreshLiveNodeTints(using states: [UUID: AnchorCoverageState]) {
        for (id, node) in trackedNodes {
            guard let material = node.geometry?.firstMaterial else { continue }
            let state = states[id]
            applyCoverageTint(
                to: material,
                coverageScore: state?.coverageScore ?? 0,
                bucket: state?.bucket ?? .low
            )
        }
    }

    private func averageCoverage(
        for classification: ARMeshClassification,
        in states: [UUID: AnchorCoverageState]
    ) -> Double {
        let matching = states.values.filter { $0.classification == classification }
        guard !matching.isEmpty else { return 0 }
        let sum = matching.reduce(0.0) { $0 + Double($1.coverageScore) }
        return min(1.0, max(0.0, sum / Double(matching.count)))
    }

    private func count(
        of classification: ARMeshClassification,
        in states: [UUID: AnchorCoverageState]
    ) -> Int {
        states.values.filter { $0.classification == classification }.count
    }

    private func makeWeakAreaHint(
        from states: [UUID: AnchorCoverageState]
    ) -> WeakAreaHint? {
        let candidates = states.compactMap { entry -> (id: UUID, state: AnchorCoverageState)? in
            let state = entry.value
            guard state.coverageScore < 0.70,
                  (state.classification == .wall || state.classification == .floor || state.classification == .ceiling)
            else {
                return nil
            }
            return (entry.key, state)
        }

        guard let frame = arSession?.currentFrame else {
            resetWeakAreaTracking()
            return nil
        }

        guard let weakest = candidates.min(by: { $0.state.coverageScore < $1.state.coverageScore }) ??
                states.min(by: { $0.value.coverageScore < $1.value.coverageScore }).map({ ($0.key, $0.value) }),
              weakest.state.coverageScore < 0.70
        else {
            resetWeakAreaTracking()
            return nil
        }

        let now = frame.timestamp
        let selected = resolveWeakTarget(
            weakest: weakest,
            candidates: candidates,
            now: now
        )
        let cam = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let forward = simd_normalize(SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z))
        let right = simd_normalize(SIMD3<Float>(cam.columns.0.x, cam.columns.0.y, cam.columns.0.z))
        let up = simd_normalize(SIMD3<Float>(cam.columns.1.x, cam.columns.1.y, cam.columns.1.z))

        let toTarget = selected.state.centroid - camPos
        let x = simd_dot(toTarget, right)
        let y = simd_dot(toTarget, up)
        let z = simd_dot(toTarget, forward)

        var nx: Float = 0
        var ny: Float = 0
        if z > 0.05 {
            nx = x / z
            ny = y / z
        } else {
            nx = x >= 0 ? 1.4 : -1.4
            ny = y >= 0 ? 1.0 : -1.0
        }

        let isOnScreen = z > 0.05 && abs(nx) <= 0.60 && abs(ny) <= 0.45
        let clampedX = max(0.08, min(0.92, CGFloat((nx / 1.2) + 0.5)))
        let clampedY = max(0.10, min(0.90, CGFloat(0.5 - (ny / 0.9))))
        let hDir = x > 0.08 ? 1 : (x < -0.08 ? -1 : 0)
        let vDir = y > 0.08 ? 1 : (y < -0.08 ? -1 : 0)

        let dwellProgress: CGFloat
        let label: String
        if isOnScreen {
            if activeWeakTargetVisibleSince == nil {
                activeWeakTargetVisibleSince = now
            }
            let heldFor = max(0, now - (activeWeakTargetVisibleSince ?? now))
            dwellProgress = min(1.0, CGFloat(heldFor / weakAreaHoldDuration))
            if dwellProgress < 1.0 {
                let remaining = max(0, weakAreaHoldDuration - heldFor)
                let remainingLabel = String(format: "%.1fs", remaining)
                label = "Hold on this \(Self.label(for: selected.state.classification)) \(remainingLabel)"
            } else {
                label = "Good coverage — sweep across this \(Self.label(for: selected.state.classification))"
            }
        } else {
            activeWeakTargetVisibleSince = nil
            dwellProgress = 0
            label = "Pan \(Self.directionLabel(horizontal: hDir, vertical: vDir)): \(Self.label(for: selected.state.classification))"
        }

        return WeakAreaHint(
            label: label,
            normalizedX: clampedX,
            normalizedY: clampedY,
            isOnScreen: isOnScreen,
            horizontalDirection: hDir,
            verticalDirection: vDir,
            dwellProgress: dwellProgress
        )
    }

    private func resolveWeakTarget(
        weakest: (id: UUID, state: AnchorCoverageState),
        candidates: [(id: UUID, state: AnchorCoverageState)],
        now: TimeInterval
    ) -> (id: UUID, state: AnchorCoverageState) {
        guard let activeWeakTargetID,
              let active = candidates.first(where: { $0.id == activeWeakTargetID })
        else {
            activeWeakTargetID = weakest.id
            activeWeakTargetLockedAt = now
            activeWeakTargetVisibleSince = nil
            return weakest
        }

        let lockAge = now - activeWeakTargetLockedAt
        let activeStillCompetitive = active.state.coverageScore <= weakest.state.coverageScore + 0.10
        if lockAge < weakAreaStickyDuration || activeStillCompetitive {
            return active
        }

        if weakest.id != activeWeakTargetID {
            self.activeWeakTargetID = weakest.id
            self.activeWeakTargetLockedAt = now
            self.activeWeakTargetVisibleSince = nil
        }
        return weakest
    }

    private func resetWeakAreaTracking() {
        activeWeakTargetID = nil
        activeWeakTargetLockedAt = 0
        activeWeakTargetVisibleSince = nil
    }

    private func applyCoverageTint(
        to material: SCNMaterial,
        coverageScore: Float,
        bucket: AnchorCoverageBucket
    ) {
        let alpha = CGFloat(max(0.06, 0.30 - (0.22 * CGFloat(coverageScore))))
        material.emission.contents = Self.tintColor(for: bucket).withAlphaComponent(alpha)
    }

    private static func tintColor(for bucket: AnchorCoverageBucket) -> UIColor {
        switch bucket {
        case .low:
            return UIColor.systemRed
        case .medium:
            return UIColor.systemYellow
        case .high:
            return UIColor.systemGreen
        }
    }

    private static func classificationConfidence(for classification: ARMeshClassification) -> Float {
        switch classification {
        case .wall, .floor, .ceiling:
            return 1.0
        case .table, .seat, .window, .door:
            return 0.85
        case .none:
            return 0.70
        @unknown default:
            return 0.70
        }
    }

    private static func label(for classification: ARMeshClassification) -> String {
        switch classification {
        case .wall:    return "wall"
        case .floor:   return "floor"
        case .ceiling: return "ceiling"
        case .table:   return "table"
        case .seat:    return "seat"
        case .window:  return "window"
        case .door:    return "door"
        case .none:    return "area"
        @unknown default: return "area"
        }
    }

    private static func directionLabel(horizontal: Int, vertical: Int) -> String {
        switch (horizontal, vertical) {
        case (-1, 1): return "up-left"
        case (0, 1): return "up"
        case (1, 1): return "up-right"
        case (-1, 0): return "left"
        case (1, 0): return "right"
        case (-1, -1): return "down-left"
        case (0, -1): return "down"
        case (1, -1): return "down-right"
        default: return "around"
        }
    }

    func roomPlanObjectCoverage(for objects: [RoomPlanDetectedObject]) -> [RoomPlanObjectCoverage] {
        guard !objects.isEmpty else { return [] }
        return objects.map { object in
            let nearby = anchorCoverageByID.values.filter {
                objectContainsAnchorCentroid(
                    objectTransform: object.transform,
                    objectDimensions: object.dimensions,
                    centroid: $0.centroid
                )
            }
            let minCoverage = nearby.map(\.coverageScore).min() ?? 0
            return RoomPlanObjectCoverage(
                id: object.id,
                label: object.label,
                coverageScore: minCoverage,
                needsMoreCoverage: !nearby.isEmpty && minCoverage < 0.70
            )
        }
    }

    private func objectContainsAnchorCentroid(
        objectTransform: simd_float4x4,
        objectDimensions: SIMD3<Float>,
        centroid: SIMD3<Float>
    ) -> Bool {
        let halfExtents = objectDimensions * 0.5
        let padding = SIMD3<Float>(
            repeating: max(0.18, max(objectDimensions.x, objectDimensions.z) * 0.08)
        )
        let inverse = objectTransform.inverse
        let local = simd_mul(inverse, SIMD4<Float>(centroid.x, centroid.y, centroid.z, 1))
        return abs(local.x) <= halfExtents.x + padding.x &&
               abs(local.y) <= halfExtents.y + padding.y &&
               abs(local.z) <= halfExtents.z + padding.z
    }

    func roomPlanCoveragePrompt(for objects: [RoomPlanDetectedObject]) -> String? {
        guard !objects.isEmpty else { return nil }
        var weakestPrompt: (label: String, score: Float)?
        for objectCoverage in roomPlanObjectCoverage(for: objects) {
            guard objectCoverage.needsMoreCoverage else { continue }
            let label = "You haven't fully scanned the \(objectCoverage.label.lowercased()) — walk around it once more."
            if weakestPrompt == nil || objectCoverage.coverageScore < weakestPrompt!.score {
                weakestPrompt = (label, objectCoverage.coverageScore)
            }
        }
        return weakestPrompt?.label
    }

    /// Pick the most frequent classification among the anchor's faces. We
    /// sample up to the first 1024 faces — a chunk that big is uncommon
    /// and the dominant class converges quickly.
    private static func dominantClass(of anchor: ARMeshAnchor) -> ARMeshClassification {
        guard let cls = anchor.geometry.classification else { return .none }
        let count = min(cls.count, 1024)
        guard count > 0 else { return .none }
        let base = cls.buffer.contents().advanced(by: cls.offset)
        var hist = [Int](repeating: 0, count: 8)
        for i in 0..<count {
            let raw = base.advanced(by: i * cls.stride)
                .assumingMemoryBound(to: UInt8.self).pointee
            if raw < 8 { hist[Int(raw)] += 1 }
        }
        var bestIdx = 0
        var bestCount = -1
        for (i, n) in hist.enumerated() where n > bestCount {
            bestCount = n
            bestIdx = i
        }
        return ARMeshClassification(rawValue: bestIdx) ?? .none
    }
}
