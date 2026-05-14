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
        didSet { refreshOverlayOpacities() }
    }

    /// Re-apply opacity to every tracked node based on `isEnabled` AND the
    /// anchor's current texture quality. An anchor below
    /// `minTextureQualityForOverlay` is hidden even when the overlay is
    /// globally on — showing a "white blur" claim for an area we don't
    /// actually have a usable photo of is worse than showing nothing.
    private func refreshOverlayOpacities() {
        for (id, node) in trackedNodes {
            let quality = textureQualityByAnchor[id] ?? 0
            let show = isEnabled && quality >= minTextureQualityForOverlay
            node.opacity = show ? 1.0 : 0.0
        }
    }

    @Published private(set) var anchorCount: Int = 0

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
        anchorCentroidByID.removeAll()
        textureQualityByAnchor.removeAll()
        anchorCount = 0
        latestSnapshot = nil
    }

    /// Free the per-anchor ring-buffer snapshots (~5 MB × anchor count =
    /// ~250 MB for a typical room) without touching geometry, the anchor
    /// dictionary, or the live SCN nodes.
    ///
    /// CaptureView calls this after taking ExplorerSnapshots and before
    /// kicking off the atlas bake — the bake's own temporaries already
    /// own everything they need, and holding a duplicate copy in memory
    /// during the bake is exactly what jetsam-kills the app.
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
        /// Per-vertex UVs (SIMD2<Float>) baked from the frozen camera snapshot.
        let uvData: Data
        /// World-space AABB of the vertices after applying worldTransform.
        let worldMin: SIMD3<Float>
        let worldMax: SIMD3<Float>
        /// The first-sighting RGB photo to drape on this anchor.
        let textureImage: UIImage
    }

    /// Snapshot of every currently-textured anchor for hand-off to the
    /// MeshExplorerView. Reads each anchor's raw Metal buffers and copies
    /// every byte into freshly-allocated `Data` so the resulting array is
    /// fully independent of ARKit's live state.
    ///
    /// Uses the best-scoring snapshot from each anchor's ring buffer (the
    /// camera view that was actually pointed at the anchor, sharply, from
    /// a reasonable distance) — NOT the first-sighting snapshot, which is
    /// what produced the long horizontal smears in the legacy renderer.
    func snapshotForExplorer() -> [ExplorerSnapshot] {
        var out: [ExplorerSnapshot] = []
        out.reserveCapacity(trackedNodes.count)
        var skippedLowQuality = 0
        for (id, anchor) in anchorsByID {
            // Skip anchors whose best snapshot couldn't project most of
            // the mesh into a real UV range. Including them would render
            // as a black distorted patch in the explorer (sentinel UVs
            // hit the grey-fallback fragment-modifier path). Better to
            // have a hole in the explorer's visible mesh than a smear —
            // the physics body still covers the missing area via the
            // coarse-welded mesh built from ALL anchors, so the user
            // can still walk through that space, they just won't see it.
            let quality = textureQualityByAnchor[id] ?? 0
            guard quality >= minTextureQualityForOverlay else {
                skippedLowQuality += 1
                continue
            }
            guard let snap = bestSnapshot(forAnchorID: id) else { continue }
            guard let owned = ownGeometryFromAnchor(anchor: anchor, snapshot: snap) else { continue }
            out.append(owned)
        }
        if skippedLowQuality > 0 {
            // Audit signal for the Debug log — tells us how many anchors
            // the user scanned without ever framing well. A high count
            // means coverage was thin; downstream layers can guide the
            // user to retake those regions.
            NSLog("[TexturedMeshRenderer] snapshotForExplorer skipped " +
                  "\(skippedLowQuality) anchors below quality threshold " +
                  "\(minTextureQualityForOverlay)")
        }
        return out
    }

    /// Read the ARMeshAnchor's raw geometry buffers directly, copy bytes
    /// into freshly-allocated `Data`, recompute UVs from the frozen camera
    /// matrices, and bundle the texture UIImage. The resulting snapshot
    /// shares no Metal buffer with ARKit.
    private func ownGeometryFromAnchor(
        anchor: ARMeshAnchor,
        snapshot: CameraSnapshot
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

        // ── UVs from the chosen best-view snapshot ─────────────────────
        // Same sentinel rule as makeTexturedGeometry: vertices that don't
        // project cleanly into the snapshot's [0.05, 0.95] inset get UV
        // (-1, -1), and the explorer's fragment shader replaces them with
        // neutral grey. Without this the texture's edge pixels would smear
        // across walls in the explorer view.
        let viewProj = simd_mul(snapshot.projectionMatrix, snapshot.viewMatrix)
        let sentinel = SIMD2<Float>(-1, -1)
        var uvs = [SIMD2<Float>](repeating: sentinel, count: vertexCount)
        for i in 0..<vertexCount {
            let p = verts[i]
            let world = simd_mul(xform, SIMD4<Float>(p.x, p.y, p.z, 1))
            let clip = simd_mul(viewProj, world)
            if clip.w <= 0 { continue }
            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            let u: Float = Float((ndcX * 0.5) + 0.5)
            let v: Float = Float(1.0 - ((ndcY * 0.5) + 0.5))
            if u < 0.05 || u > 0.95 || v < 0.05 || v > 0.95 { continue }
            uvs[i] = SIMD2(u, v)
        }
        let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }

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
            uvData: uvData,
            worldMin: wmin,
            worldMax: wmax,
            textureImage: snapshot.image
        )
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

    /// Per-anchor textured-UV coverage in [0, 1]. Computed by
    /// `makeTexturedGeometry` as (validUVCount / vertCount). An anchor
    /// whose best snapshot was taken from a tangential angle has most
    /// vertices projecting outside the texture frustum → sentinel UVs
    /// → low quality. We use this to:
    ///   1. Hide the live overlay (set opacity to 0) so the user doesn't
    ///      see a misleading "white blur" claiming an area is textured
    ///      when it actually has nothing useful baked.
    ///   2. Filter snapshotForExplorer so the explorer never receives
    ///      anchors that would render as a black distorted patch.
    /// Refreshed on every didAdd / didUpdate.
    private var textureQualityByAnchor: [UUID: Float] = [:]

    /// Threshold below which an anchor is considered "not actually
    /// textured" — fewer than this fraction of its vertices project
    /// into the chosen snapshot's [0.05, 0.95] inset.
    private let minTextureQualityForOverlay: Float = 0.30

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Texture target side length. 512 is plenty for the hand-held overlay
    /// and keeps GPU memory bounded across many anchors.
    private let textureMaxDimension: CGFloat = 512

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
        /// Mean luminance in [0, 1], Rec.709 weighted. Computed once in
        /// makeSnapshot via CIAreaAverage. Used by `score` to penalise
        /// blown-out (mean ≈ 1.0) and crushed-black (mean ≈ 0.0) frames,
        /// which is what was happening near bright lights and producing
        /// the visible seam in the explorer.
        let meanLuminance: Float
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
            self?.anchorCentroidByID.removeValue(forKey: id)
            self?.anchorCount = self?.trackedNodes.count ?? 0
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
        //
        // Phase D — the "stuck band" fix. After `consider` mutates the
        // ring buffer, check whether the BEST slot changed for this
        // anchor. If yes, re-install the textured geometry so the new
        // UV layout (computed against the new best snapshot's matrices)
        // actually reaches the SCN node. Without this step the ring
        // buffer accumulates better and better snapshots but the
        // rendered material stays frozen with the original layout —
        // exactly the bug the user reported as vertical bands that
        // never fill in.
        //
        // Why this fix is needed at all: ARKit stops calling didUpdate
        // on a mesh anchor once its geometry stabilises. `installTextured-
        // Mesh` is normally the path that re-bakes textures, but it
        // only runs from didAdd/didUpdate. A stable anchor whose ring
        // buffer keeps improving via the pump above had no way to
        // promote those improvements to the renderer — until now.
        for (id, _) in anchorCentroidByID {
            let oldBestTimestamp = bestSnapshot(forAnchorID: id)?.timestamp
            consider(snapshot: snap, forAnchorID: id)
            let newBest = bestSnapshot(forAnchorID: id)
            // Compare by timestamp — each ARFrame has a unique timestamp,
            // so this is an identity check.
            let bestChanged = newBest?.timestamp != oldBestTimestamp
            guard bestChanged,
                  let node = trackedNodes[id],
                  let anchor = anchorsByID[id] else {
                continue
            }
            // Re-bake. installTexturedMesh re-runs UV projection against
            // the new best snapshot, rebuilds the SCN geometry + material,
            // and re-applies the Phase B quality-aware opacity gate. The
            // band fills in (or, for the rare-but-legitimate case where
            // a snapshot won on score but produces worse UV coverage,
            // the band stays hidden under Phase B's threshold — which is
            // still better than the prior behavior of pretending it was
            // textured).
            installTexturedMesh(into: node, from: anchor, isNew: false)
        }
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

    /// Score a snapshot's suitability as the texture for an anchor.
    ///
    /// The product of FOUR factors, each in [0, 1]:
    ///  - **view-angle**: cosine of the angle between camera forward and
    ///    direction-to-anchor. 1.0 = camera pointed straight at anchor,
    ///    0.0 = perpendicular or behind. We clamp to 0 below; a camera
    ///    facing AWAY from the anchor must never win the slot.
    ///  - **distance**: 1.0 at <0.5 m, falling off as 1/d. Closer photos
    ///    have higher pixel density per face → sharper texture.
    ///  - **sharpness**: BlurDetector value normalised to [0, 1]. A motion-
    ///    blurred frame can never beat a sharp one.
    ///  - **exposure**: 1.0 at mean-luma 0.5, falling off linearly to 0
    ///    at 0.0 (crushed black) or 1.0 (blown-out white). Floored at
    ///    0.1 so a usable-but-bright frame can still win if it's the
    ///    only candidate. This is the change that fixes the "seam near
    ///    bright lights" symptom — a sharp washed-out photo of a wall
    ///    next to a lamp used to beat a mid-exposed photo from a step
    ///    back, baking the seam into the explorer.
    ///
    /// All four must be reasonable; one weak factor near-zeros the score.
    private func score(
        snapshot snap: CameraSnapshot,
        anchorCentroid centroid: SIMD3<Float>
    ) -> Float {
        let toAnchor = centroid - snap.cameraPosition
        let dist = simd_length(toAnchor)
        if dist < 1e-3 { return 0 }
        let dir = toAnchor / dist
        let dot = simd_dot(snap.cameraForward, dir)
        let viewScore: Float = max(0, dot)              // [0, 1]
        let distScore: Float = min(1, 2.0 / max(dist, 0.5))  // 1 at <0.5m
        let sharpScore: Float = min(1, max(0, snap.sharpness))
        // Triangle window centred at 0.5 luma → mid-exposure wins.
        // 0.1 floor so a slightly bright frame still beats nothing.
        let exposureScore: Float = max(
            0.1,
            1.0 - 2.0 * abs(snap.meanLuminance - 0.5)
        )
        return viewScore * distScore * sharpScore * exposureScore
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

        // Mean luminance — CIAreaAverage produces a 1×1 pixel containing
        // the average colour of `ci`. Render to 4 bytes and compute
        // Rec.709 luma in [0, 1]. Cheap (~1-2 ms) because we render at
        // 1×1 and CI fuses the reduction onto the GPU. Used by `score`
        // to penalise blown-out and crushed frames so the candidate
        // ring-buffer prefers mid-exposure photos. Without this, a
        // sharply-focused near-white frame next to a light bulb beats
        // a mid-exposure photo of the same surface and the explorer
        // shows a visible seam at the light's edge.
        let meanLuminance: Float = {
            let avgFilter = CIFilter(name: "CIAreaAverage")
            avgFilter?.setValue(ci, forKey: kCIInputImageKey)
            avgFilter?.setValue(CIVector(cgRect: ci.extent),
                                forKey: "inputExtent")
            guard let avg = avgFilter?.outputImage else { return 0.5 }
            var pixel: [UInt8] = [0, 0, 0, 0]
            ciContext.render(
                avg,
                toBitmap: &pixel,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            let r = Float(pixel[0]) / 255.0
            let g = Float(pixel[1]) / 255.0
            let b = Float(pixel[2]) / 255.0
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }()

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
            meanLuminance: meanLuminance,
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
        if let snap = bestSnapshot(forAnchorID: id),
           let result = makeTexturedGeometry(from: anchor, snapshot: snap) {
            let material = makeTexturedMaterial(image: snap.image)
            result.geometry.materials = [material]
            node.geometry = result.geometry
            textureQualityByAnchor[id] = result.quality
        } else {
            // No snapshot yet (first second of capture before the pump has
            // fired). Show the translucent teal fallback so the user sees
            // something; the next didUpdate will retro-fit a real texture.
            //
            // Quality = 0 here (no real UVs). The opacity gate below will
            // hide this node, so the user no longer sees the teal blur
            // claiming a brand-new anchor is "already covered." The node
            // becomes visible the moment a snapshot with reasonable
            // projection coverage arrives via the next didUpdate.
            let geom = makeFlatGeometry(from: anchor)
            geom.materials = [makeFlatMaterial()]
            node.geometry = geom
            textureQualityByAnchor[id] = 0
        }

        // Quality-aware opacity. An anchor with mostly-sentinel UVs would
        // sample the texture's clamped top-left pixel everywhere and look
        // like a white smear, lying to the user that this surface is
        // captured. We hide it instead — see comment on
        // `textureQualityByAnchor`.
        let quality = textureQualityByAnchor[id] ?? 0
        let showOverlay = isEnabled && quality >= minTextureQualityForOverlay
        node.opacity = showOverlay ? 1.0 : 0.0

        if isNew || trackedNodes[id] == nil {
            trackedNodes[id] = node
            anchorCount = trackedNodes.count
        }
        // Always refresh the anchor pointer; ARKit hands us the same anchor
        // object across didAdd/didUpdate, but we want our reference to track
        // the latest geometry generation regardless.
        anchorsByID[id] = anchor
    }

    /// Build SCNGeometry with vertex positions, normals, and **per-vertex
    /// texture coordinates** computed by projecting each world-space vertex
    /// through the snapshot camera. Returns nil if the projection produced
    /// no valid UVs (e.g. snapshot pose data was malformed).
    ///
    /// Returns `(geometry, textureQuality)` where `textureQuality` is the
    /// fraction of vertices that projected INSIDE the [0.05, 0.95] inset
    /// (i.e. got a real UV, not the sentinel). Caller uses this to gate
    /// node opacity + explorer export — see `textureQualityByAnchor`.
    private func makeTexturedGeometry(
        from anchor: ARMeshAnchor,
        snapshot: CameraSnapshot
    ) -> (geometry: SCNGeometry, quality: Float)? {
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
        var validUVCount = 0
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
            validUVCount += 1
        }
        let quality: Float = vertCount > 0
            ? Float(validUVCount) / Float(vertCount)
            : 0

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

        return (SCNGeometry(sources: sources, elements: [element]), quality)
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

    private func makeTexturedMaterial(image: UIImage) -> SCNMaterial {
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
        return m
    }

    private func makeFlatMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.30)
        m.transparency = 0.30
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        return m
    }
}
