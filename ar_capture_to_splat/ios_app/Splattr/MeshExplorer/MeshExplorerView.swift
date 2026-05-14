//
//  MeshExplorerView.swift
//  Post-scan explorer — PER-ANCHOR rendering (Phase 1's proven path).
//
//  Phase 2's atlas bake produced grayscale output despite many fix
//  attempts (texture format, storage mode, blit usage flags, sRGB
//  encoding, MTLTexture→UIImage conversion). Reverted to per-anchor
//  rendering which is what produced Phase 1's working bed-corner shot.
//  All Phase 2 capture-side infrastructure (CandidateViewPool,
//  MeshAtlasBaker) is retained for future debugging — the explorer
//  just doesn't consume its output for now.
//
//  This screen takes [TexturedMeshRenderer.ExplorerSnapshot] directly
//  and renders one SCNNode per anchor:
//    - Per-anchor SCNGeometry built from the snapshot's
//      vertex/normal/index/uv data (UVs were computed in
//      TexturedMeshRenderer's per-anchor projection — same call path
//      that gave us the bed corner).
//    - Per-anchor diffuse: snapshot.textureImage (UIImage), the
//      best-view photo for that anchor. Phase 1's UIImage path is
//      empirically correct for SCNMaterialProperty.contents.
//    - Single coarse-welded physics body (8 cm grid) so SCNPhysicsShape
//      concavePolyhedron builds fast (<200 ms) without freezing the
//      main thread on the cover present.
//    - First-person controller, joystick + look pad, jump.
//

import SwiftUI
import SceneKit
import UIKit
import simd

// ── SwiftUI screen ───────────────────────────────────────────────────────────

struct MeshExplorerView: View {

    /// Two render paths share the same SwiftUI shell and FPS controller:
    ///   - `.perAnchor` — Phase 1, one SCNNode per ARMeshAnchor with the
    ///                    per-anchor best-view UIImage. Proven path.
    ///   - `.atlas`     — Phase 2 atlas bake (BakedMesh.chunks). One
    ///                    SCNNode per atlas chunk with a single atlas
    ///                    UIImage. Selected when CaptureView passes a
    ///                    successfully-baked + diagnostically-clean mesh.
    enum Source {
        case perAnchor([TexturedMeshRenderer.ExplorerSnapshot])
        case atlas(BakedMesh)
    }

    let source: Source

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = FirstPersonController()
    @State private var stickValue: SIMD2<Float> = .zero

    /// Phase 1 entry point — kept stable for the existing fallback path.
    init(snapshots: [TexturedMeshRenderer.ExplorerSnapshot]) {
        self.source = .perAnchor(snapshots)
    }

    /// Phase 2 entry point — atlas-baked render.
    init(baked: BakedMesh) {
        self.source = .atlas(baked)
    }

    var body: some View {
        ZStack {
            ExplorerSceneKitView(
                source: source,
                controller: controller
            )
            .ignoresSafeArea()
            controlsOverlay
        }
        .preferredColorScheme(.dark)
        .background(Color.black)
        .onDisappear { controller.stopMovementLoop() }
    }

    private var controlsOverlay: some View {
        ZStack {
            // Split-screen drag regions (joystick on left half, look on right)
            HStack(spacing: 0) {
                joystickPad
                lookPad
            }
            // HUD on top
            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text("EXPLORE MODE")
                .font(.system(size: 11, weight: .heavy)).tracking(2.0)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.6))
            Spacer()
            Button {
                controller.stopMovementLoop()
                dismiss()
            } label: {
                Text("EXIT")
                    .font(.system(size: 12, weight: .heavy)).tracking(1.6)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 60)
    }

    private var bottomBar: some View {
        HStack {
            Text(String(format: "POS  %+.1f, %+.1f, %+.1f",
                        controller.cameraWorldPosition.x,
                        controller.cameraWorldPosition.y,
                        controller.cameraWorldPosition.z))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.ultraThinMaterial))
            Spacer()
            jumpButton
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 38)
    }

    private var joystickPad: some View {
        VirtualJoystick(value: $stickValue) { v in
            controller.setMovementInput(v)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var lookPad: some View {
        LookPad { delta in
            controller.applyLookDelta(delta)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var jumpButton: some View {
        Button {
            controller.requestJump()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.5), radius: 6)
        }
        .buttonStyle(.plain)
    }
}

// ── SCNView host ─────────────────────────────────────────────────────────────

private struct ExplorerSceneKitView: UIViewRepresentable {
    let source: MeshExplorerView.Source
    let controller: FirstPersonController

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        v.antialiasingMode = .multisampling2X
        v.preferredFramesPerSecond = 60
        v.allowsCameraControl = false
        v.autoenablesDefaultLighting = false
        v.rendersContinuously = true
        let scene = buildScene()
        v.scene = scene

        let (wmin, wmax) = worldBounds()
        controller.attach(
            scene: scene,
            sceneView: v,
            sceneBounds: SceneBoundsDescriptor(minBound: wmin, maxBound: wmax)
        )
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Scene is built once and lives for the explorer's lifetime.
    }

    /// Pick the AABB based on which source we're rendering.
    private func worldBounds() -> (SIMD3<Float>, SIMD3<Float>) {
        switch source {
        case .perAnchor(let snapshots):
            var wmin = SIMD3<Float>(.infinity, .infinity, .infinity)
            var wmax = SIMD3<Float>(-.infinity, -.infinity, -.infinity)
            for snap in snapshots {
                wmin = simd_min(wmin, snap.worldMin)
                wmax = simd_max(wmax, snap.worldMax)
            }
            if !wmin.x.isFinite {
                wmin = SIMD3(-1, -1, -1); wmax = SIMD3(1, 1, 1)
            }
            return (wmin, wmax)
        case .atlas(let baked):
            return (baked.worldMin, baked.worldMax)
        }
    }

    /// Dispatches to the appropriate render path. Both share the same
    /// physics + lighting setup so navigation feels identical regardless
    /// of which path was chosen.
    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        scene.physicsWorld.gravity = SCNVector3(0, -9.81, 0)
        scene.physicsWorld.timeStep = 1.0 / 90.0

        switch source {
        case .perAnchor(let snapshots):
            buildPerAnchorRender(scene: scene, snapshots: snapshots)
            buildPhysics(scene: scene,
                         vertices: nil, triangles: nil,
                         fromSnapshots: snapshots)
        case .atlas(let baked):
            buildAtlasRender(scene: scene, baked: baked)
            buildPhysics(scene: scene,
                         vertices: baked.physicsVertices,
                         triangles: baked.physicsTriangles,
                         fromSnapshots: nil)
        }

        // ── Lighting ────────────────────────────────────────────────────
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 1000
        amb.light?.color = UIColor.white
        scene.rootNode.addChildNode(amb)

        return scene
    }

    /// Phase 1: one SCNNode per ARMeshAnchor with the per-anchor best-view
    /// UIImage. Each anchor's geometry is in anchor-local space + a parent
    /// worldTransform — same path that produced the bed-corner shot.
    private func buildPerAnchorRender(
        scene: SCNScene,
        snapshots: [TexturedMeshRenderer.ExplorerSnapshot]
    ) {
        for snap in snapshots {
            guard let geom = makeAnchorGeometry(from: snap) else { continue }
            geom.materials = [makeAnchorMaterial(image: snap.textureImage)]
            let node = SCNNode(geometry: geom)
            node.simdTransform = snap.worldTransform
            node.castsShadow = false
            scene.rootNode.addChildNode(node)
        }
    }

    /// Phase 2: one SCNNode per BakedChunk. Vertices are already in
    /// world space (bake's render-vertex pass world-transformed them)
    /// so the node sits at identity. Atlas UIImage is the diffuse —
    /// same SCN content path Phase 1 uses (UIImage, NOT MTLTexture,
    /// per the silent-grayscale lesson logged in
    /// [[feedback_scnmaterial_uiimage_path]]).
    private func buildAtlasRender(scene: SCNScene, baked: BakedMesh) {
        for chunk in baked.chunks {
            guard let geom = makeAtlasChunkGeometry(chunk: chunk) else { continue }
            geom.materials = [makeAtlasMaterial(image: chunk.atlas)]
            let node = SCNNode(geometry: geom)
            // chunk.renderVertices are pre-multiplied into world space
            // by the bake — no node transform needed.
            node.castsShadow = false
            scene.rootNode.addChildNode(node)
        }
    }

    /// Shared physics setup. For Phase 1 we compute the coarse welded
    /// mesh from snapshots on demand; for Phase 2 the bake already
    /// produced it. Either way the SCNPhysicsShape concavePolyhedron is
    /// built on a coarse mesh (8 cm grid) so it constructs in <200 ms
    /// without freezing the main thread — see
    /// [[feedback_concave_polyhedron_size]].
    private func buildPhysics(
        scene: SCNScene,
        vertices preComputedVerts: [SIMD3<Float>]?,
        triangles preComputedTris: [SIMD3<UInt32>]?,
        fromSnapshots snapshots: [TexturedMeshRenderer.ExplorerSnapshot]?
    ) {
        let verts: [SIMD3<Float>]
        let tris: [SIMD3<UInt32>]
        if let v = preComputedVerts, let t = preComputedTris {
            verts = v;  tris = t
        } else if let snaps = snapshots {
            let coarse = MeshAtlasBaker.makeCoarseWeldedMesh(snapshots: snaps)
            verts = coarse.vertices;  tris = coarse.triangles
        } else {
            return
        }
        guard !tris.isEmpty else { return }

        let physGeom = makeWeldedPhysicsGeometry(vertices: verts, triangles: tris)
        let body = SCNPhysicsBody(
            type: .static,
            shape: SCNPhysicsShape(
                geometry: physGeom,
                options: [.type: SCNPhysicsShape.ShapeType.concavePolyhedron]
            )
        )
        body.friction = 0.6
        body.restitution = 0.0
        let physNode = SCNNode(geometry: physGeom)
        physNode.physicsBody = body
        physNode.opacity = 0.0
        physNode.castsShadow = false
        scene.rootNode.addChildNode(physNode)
    }

    // MARK: - Geometry construction

    /// Build SCNGeometry for ONE anchor from its ExplorerSnapshot.
    /// Vertices are in anchor-local space (the snapshot's vertexData);
    /// we hand SCN the snapshot's worldTransform on the parent node so
    /// the geometry sits in world space at render time.
    private func makeAnchorGeometry(
        from snap: TexturedMeshRenderer.ExplorerSnapshot
    ) -> SCNGeometry? {
        guard snap.vertexCount > 0, snap.triangleCount > 0 else { return nil }

        let vertSrc = SCNGeometrySource(
            data: snap.vertexData, semantic: .vertex,
            vectorCount: snap.vertexCount, usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.size
        )
        var sources: [SCNGeometrySource] = [vertSrc]
        if snap.normalCount == snap.vertexCount, !snap.normalData.isEmpty {
            sources.append(SCNGeometrySource(
                data: snap.normalData, semantic: .normal,
                vectorCount: snap.normalCount, usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.size
            ))
        }
        sources.append(SCNGeometrySource(
            data: snap.uvData, semantic: .texcoord,
            vectorCount: snap.vertexCount, usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.size
        ))

        let element = SCNGeometryElement(
            data: snap.indexData,
            primitiveType: .triangles,
            primitiveCount: snap.triangleCount,
            bytesPerIndex: snap.bytesPerIndex
        )
        return SCNGeometry(sources: sources, elements: [element])
    }

    /// Build SCNGeometry for ONE atlas chunk produced by MeshAtlasBaker.
    /// Each chunk carries `3 × triangleCount` UNSHARED vertices already
    /// in world space + per-vertex normals + atlas-tile UVs. No index
    /// buffer is needed — SCN draws the vertex array as plain triangles.
    private func makeAtlasChunkGeometry(chunk: BakedChunk) -> SCNGeometry? {
        guard chunk.triangleCount > 0 else { return nil }
        let vertexCount = chunk.renderVertices.count
        guard vertexCount == chunk.triangleCount * 3 else {
            DebugLog.shared.error(
                "explorer",
                "atlas chunk vertex count mismatch: " +
                "got \(vertexCount), expected \(chunk.triangleCount * 3)"
            )
            return nil
        }

        let vertData = chunk.renderVertices.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        let vertSrc = SCNGeometrySource(
            data: vertData, semantic: .vertex,
            vectorCount: vertexCount, usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.size
        )

        var sources: [SCNGeometrySource] = [vertSrc]
        if chunk.renderNormals.count == vertexCount {
            let normData = chunk.renderNormals.withUnsafeBufferPointer {
                Data(buffer: $0)
            }
            sources.append(SCNGeometrySource(
                data: normData, semantic: .normal,
                vectorCount: vertexCount, usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.size
            ))
        }

        let uvData = chunk.renderUVs.withUnsafeBufferPointer { Data(buffer: $0) }
        sources.append(SCNGeometrySource(
            data: uvData, semantic: .texcoord,
            vectorCount: vertexCount, usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.size
        ))

        // No index buffer — UNSHARED verts in draw order. UInt32 indices
        // wrapping `0...vertexCount-1` would just duplicate the layout.
        let indices = [UInt32](0..<UInt32(vertexCount))
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: chunk.triangleCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        return SCNGeometry(sources: sources, elements: [element])
    }

    /// Build the coarse-welded physics geometry. No UVs — only used to
    /// construct the concavePolyhedron physics shape.
    private func makeWeldedPhysicsGeometry(
        vertices: [SIMD3<Float>],
        triangles: [SIMD3<UInt32>]
    ) -> SCNGeometry {
        let vertData = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertSrc = SCNGeometrySource(
            data: vertData, semantic: .vertex,
            vectorCount: vertices.count, usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.size
        )
        let indexData = triangles.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: triangles.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        return SCNGeometry(sources: [vertSrc], elements: [element])
    }

    // MARK: - Material

    /// Phase 1's PROVEN material: UIImage diffuse with a fragment shader
    /// modifier that replaces out-of-[0.005, 0.995] UVs with neutral
    /// grey. UVs come from the snapshot's per-anchor projection — most
    /// land inside [0, 1], some sliver fragments fall outside and would
    /// otherwise sample edge pixels (smearing). The shader catches them.
    /// Atlas material — same UIImage path as Phase 1 (NOT MTLTexture; see
    /// [[feedback_scnmaterial_uiimage_path]]). NO out-of-UV grey fallback
    /// in the fragment shader: the atlas bake intentionally writes inside
    /// tile bounds with a 1-pixel inset, so the only out-of-tile sampling
    /// risk is bilinear bleed at tile borders — which is bounded and
    /// invisible. Sampling outside [0,1] is impossible because the bake
    /// chose its UVs from tile pixel positions divided by atlasSize.
    private func makeAtlasMaterial(image: UIImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.transparency = 1.0
        m.isDoubleSided = true
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        return m
    }

    private func makeAnchorMaterial(image: UIImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.transparency = 1.0
        m.isDoubleSided = true
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        m.shaderModifiers = [
            .fragment: """
            #pragma transparent
            float2 _scc_uv = _surface.diffuseTexcoord;
            if (_scc_uv.x < 0.005 || _scc_uv.x > 0.995 ||
                _scc_uv.y < 0.005 || _scc_uv.y > 0.995) {
                _output.color = float4(0.45, 0.45, 0.50, 1.0);
            }
            """
        ]
        return m
    }
}

// ── First-person controller ──────────────────────────────────────────────────

/// Walk = dynamic capsule, gravity on, collisions on, jump available.
/// Fly  = kinematic capsule, gravity off, no collisions, joystick moves
///        the player in 3D (forward is wherever the camera is pointed,
///        including pitch). The explorer presents in FLY by default so a
///        bad spawn (ARKit's stray below-floor anchors, or an AABB whose
///        centre lands inside a wall) can never trap or drop the user —
///        they just float wherever they want, then can tap WALK to feel
///        the room.
enum MovementMode { case fly, walk }

@MainActor
final class FirstPersonController: ObservableObject {

    @Published private(set) var cameraWorldPosition: SIMD3<Float> = SIMD3(0, 1.6, 0)
    /// Current locomotion mode. Reactive — MeshExplorerView reads this
    /// to decide which HUD button (FLY/WALK toggle) state to render and
    /// whether to show the jump button.
    @Published private(set) var mode: MovementMode = .fly

    private(set) var playerNode: SCNNode = SCNNode()
    private(set) var cameraNode: SCNNode = SCNNode()

    private var displayLink: CADisplayLink?
    private weak var sceneView: SCNView?
    private var lastTickAt: CFTimeInterval = 0

    /// 2D movement vector from the joystick, normalized to [-1, 1].
    /// y > 0 = forward, x > 0 = strafe right.
    private var moveInput: SIMD2<Float> = .zero
    private var pendingJump: Bool = false

    /// Yaw (around +Y) and pitch (around +X), composed onto the camera node.
    private var lookYaw: Float = 0
    private var lookPitch: Float = 0

    /// Tunable.
    private let walkSpeed: Float = 2.4   // m/s — brisk walk
    private let jumpVelocity: Float = 4.5
    /// Fly-mode horizontal speed multiplier. Slightly faster than walk
    /// so inspecting ceilings + corners doesn't feel sluggish; not so
    /// fast that single-finger drags overshoot a room.
    private let flySpeedMultiplier: Float = 1.5

    init() {
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.05
        cameraNode.camera?.zFar = 200
        cameraNode.camera?.fieldOfView = 70
        cameraNode.camera?.automaticallyAdjustsZRange = true
        // Camera sits at eye height inside the player capsule.
        cameraNode.simdPosition = SIMD3(0, 0.7, 0)

        let capsule = SCNCapsule(capRadius: 0.30, height: 1.7)
        playerNode.geometry = capsule
        playerNode.geometry?.firstMaterial?.transparency = 0.0   // invisible
        playerNode.physicsBody = SCNPhysicsBody(
            type: .dynamic,
            shape: SCNPhysicsShape(geometry: capsule, options: nil)
        )
        playerNode.physicsBody?.mass = 70
        playerNode.physicsBody?.friction = 0.4
        playerNode.physicsBody?.restitution = 0.0
        playerNode.physicsBody?.damping = 0.05
        playerNode.physicsBody?.angularDamping = 1.0
        playerNode.physicsBody?.allowsResting = false
        // Lock rotation so the capsule never tips under gravity + walls.
        playerNode.physicsBody?.angularVelocityFactor = SCNVector3(0, 0, 0)

        playerNode.addChildNode(cameraNode)
    }

    func attach(scene: SCNScene, sceneView: SCNView, sceneBounds: SceneBoundsDescriptor) {
        self.sceneView = sceneView
        scene.rootNode.addChildNode(playerNode)

        // ORDER MATTERS for the first-launch black-screen fix.
        // Set the player's spawn position BEFORE assigning pointOfView so
        // the very first display-link frame uses the correct camera pose.
        // Otherwise SCNView renders frame zero with the player still at
        // origin (often outside the captured AABB → camera pointing at
        // empty space → black).
        //
        // Spawn = AABB MID-HEIGHT centre (was: minY + 1.6m floor-stand).
        // The floor-stand heuristic assumed the lowest mesh vertex was
        // the actual floor — false when ARKit drops stray below-floor
        // anchors during the first 1-2s of tracking. Mid-height keeps
        // the player inside the volume on every scan; the FLY default
        // (no gravity, no collision) means no "falling through" even
        // if some captured geometry is below where they spawn.
        let center = (sceneBounds.minBound + sceneBounds.maxBound) * 0.5
        let spawn = SIMD3<Float>(center.x, center.y, center.z)
        playerNode.simdPosition = spawn
        playerNode.physicsBody?.velocity = SCNVector3(0, 0, 0)

        // Reset look orientation on every present so a prior session's
        // pitch/yaw don't leak in. Camera looks down world -Z by default.
        lookYaw = 0
        lookPitch = 0
        applyOrientation()

        // Force FLY on every present. No-clip + no-gravity guarantees
        // the user sees their environment instead of falling out of it.
        // They can tap WALK in the HUD to engage physics.
        mode = .fly
        applyMode()

        sceneView.pointOfView = cameraNode

        // Warm up the renderer so the first display-link frame already has
        // textures + geometry uploaded to the GPU. Without this, the very
        // first present can come back blank for one or two frames while
        // SceneKit lazily uploads.
        sceneView.prepare([scene]) { _ in }

        startMovementLoop()
    }

    /// Public toggle — called from MeshExplorerView's FLY/WALK button.
    func setMode(_ new: MovementMode) {
        guard new != mode else { return }
        mode = new
        applyMode()
    }

    /// Reconfigure the physics body to match the current mode.
    ///
    /// FLY:  type = .kinematic → physics no longer applies forces or
    ///       collisions to the body. We position-drive playerNode in
    ///       displayTick. resetTransform isn't needed because SCNScene's
    ///       physics world treats kinematic nodes as authoritative.
    /// WALK: type = .dynamic → gravity + collisions re-engage. Zero out
    ///       velocity so any prior kinematic drag doesn't translate to a
    ///       sudden launch. Call resetTransform so the physics simulation
    ///       takes the current node transform as the new origin instead
    ///       of trying to reconcile a stale cached pose.
    private func applyMode() {
        guard let body = playerNode.physicsBody else { return }
        body.velocity = SCNVector3(0, 0, 0)
        switch mode {
        case .fly:
            body.type = .kinematic
            body.isAffectedByGravity = false
        case .walk:
            body.type = .dynamic
            body.isAffectedByGravity = true
            body.resetTransform()
        }
        pendingJump = false   // fly→walk shouldn't fire a stale jump
    }

    func startMovementLoop() {
        if displayLink != nil { return }
        let dl = CADisplayLink(target: self,
                               selector: #selector(displayTick(_:)))
        dl.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        dl.add(to: .main, forMode: .common)
        displayLink = dl
        lastTickAt = CACurrentMediaTime()
    }

    func stopMovementLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Input (called from SwiftUI)

    func setMovementInput(_ v: SIMD2<Float>) {
        // Clamp magnitude to 1 so diagonals don't go faster than cardinals.
        let mag = simd_length(v)
        if mag > 1 {
            moveInput = v / mag
        } else {
            moveInput = v
        }
    }

    func applyLookDelta(_ delta: SIMD2<Float>) {
        // Sensitivity tuned for fingertip drag.
        let sx: Float = 0.0035
        let sy: Float = 0.0035
        lookYaw -= delta.x * sx
        lookPitch -= delta.y * sy
        // Clamp pitch slightly inside [-π/2, π/2] to avoid gimbal flip.
        let limit: Float = (.pi / 2) - 0.05
        lookPitch = max(-limit, min(limit, lookPitch))
        applyOrientation()
    }

    func requestJump() { pendingJump = true }

    // MARK: - Per-frame integration

    @objc private func displayTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = max(0.001, min(0.05, Float(now - lastTickAt)))
        lastTickAt = now

        switch mode {
        case .fly:
            integrateFly(dt: dt)
        case .walk:
            integrateWalk()
        }

        // Mirror player position into our publisher (for the bottom-bar
        // POS readout). Reads cameraNode.simdWorldPosition either way —
        // SceneKit composes parent transforms automatically.
        cameraWorldPosition = cameraNode.simdWorldPosition
    }

    /// Walk-mode integration. Existing semantics:
    /// joystick → horizontal velocity (XZ only, ignores pitch); gravity
    /// supplies Y unless a jump is pending. Capsule's dynamic body
    /// handles collision with the room's static concavePolyhedron body.
    private func integrateWalk() {
        // Camera-space forward is -Z; yaw is around +Y. Pitch deliberately
        // ignored — walking-forward shouldn't move you up/down.
        let forward = SIMD3<Float>(-sin(lookYaw), 0, -cos(lookYaw))
        let right = SIMD3<Float>(cos(lookYaw), 0, -sin(lookYaw))
        let horiz = (forward * moveInput.y + right * moveInput.x) * walkSpeed

        guard let body = playerNode.physicsBody else { return }
        let v = body.velocity
        let vy: Float
        if pendingJump {
            vy = jumpVelocity
            pendingJump = false
        } else {
            vy = Float(v.y)
        }
        body.velocity = SCNVector3(horiz.x, vy, horiz.z)
    }

    /// Fly-mode integration. Kinematic body: SCN won't apply forces, so
    /// we move the player node directly. Movement is camera-relative in
    /// FULL 3D — looking up + push forward = move up. Strafe is
    /// horizontal-only (camera's local +X projected onto XZ would feel
    /// natural in walk; in fly we just use the camera's world +X so a
    /// rolled camera doesn't strafe weirdly, but we never roll, so it's
    /// the same vector).
    private func integrateFly(dt: Float) {
        // Read camera's world axes from its transform matrix. This is
        // robust to any composition of yawQ * pitchQ — we don't have to
        // re-derive trig.
        let m = cameraNode.simdWorldTransform
        let forwardCam = -SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let rightCam   =  SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let speed = walkSpeed * flySpeedMultiplier
        let delta = (forwardCam * moveInput.y + rightCam * moveInput.x) * speed * dt
        // Direct position drive — kinematic body honours the new pose.
        playerNode.simdPosition += delta
    }

    private func applyOrientation() {
        // Compose yaw FIRST (around world +Y), then pitch (around camera +X)
        // so look-up never twists the world.
        let yawQ = simd_quatf(angle: lookYaw, axis: SIMD3(0, 1, 0))
        let pitchQ = simd_quatf(angle: lookPitch, axis: SIMD3(1, 0, 0))
        cameraNode.simdOrientation = yawQ * pitchQ
        // Player body stays unrotated — capsule is symmetric so collisions
        // are unaffected, and we never fight the dynamic-body simulation.
    }
}

/// World-space AABB of the captured mesh snapshots. Drives where we spawn
/// the player so they never start inside a wall or below the floor.
struct SceneBoundsDescriptor {
    let minBound: SIMD3<Float>
    let maxBound: SIMD3<Float>
}

// ── Virtual joystick ─────────────────────────────────────────────────────────

private struct VirtualJoystick: View {
    @Binding var value: SIMD2<Float>
    let onChange: (SIMD2<Float>) -> Void
    @State private var dragOffset: CGSize = .zero
    @State private var active: Bool = false

    private let radius: CGFloat = 60

    var body: some View {
        GeometryReader { proxy in
            // Anchor the joystick to the bottom-left third of the pad.
            let anchor = CGPoint(x: 92, y: proxy.size.height - 100)
            ZStack {
                // Big invisible drag region that spans the full pad.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                active = true
                                let dx = g.location.x - anchor.x
                                let dy = g.location.y - anchor.y
                                let dist = sqrt(dx * dx + dy * dy)
                                let clamped: CGSize
                                if dist > radius {
                                    let s = radius / dist
                                    clamped = CGSize(width: dx * s, height: dy * s)
                                } else {
                                    clamped = CGSize(width: dx, height: dy)
                                }
                                dragOffset = clamped
                                let v = SIMD2<Float>(
                                    Float(clamped.width) / Float(radius),
                                    -Float(clamped.height) / Float(radius)
                                )
                                value = v
                                onChange(v)
                            }
                            .onEnded { _ in
                                active = false
                                dragOffset = .zero
                                value = .zero
                                onChange(.zero)
                            }
                    )

                Circle()
                    .stroke(Color.white.opacity(0.32), lineWidth: 1.4)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(anchor)
                Circle()
                    .fill(Color.white.opacity(active ? 0.85 : 0.55))
                    .frame(width: 36, height: 36)
                    .position(x: anchor.x + dragOffset.width,
                              y: anchor.y + dragOffset.height)
                    .shadow(color: .white.opacity(0.5), radius: active ? 14 : 4)
                    .animation(.easeOut(duration: 0.12), value: active)
            }
        }
    }
}

// ── Drag-to-look pad ─────────────────────────────────────────────────────────

private struct LookPad: View {
    let onDelta: (SIMD2<Float>) -> Void
    @State private var lastLocation: CGPoint?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if let last = lastLocation {
                            let dx = Float(g.location.x - last.x)
                            let dy = Float(g.location.y - last.y)
                            onDelta(SIMD2(dx, dy))
                        }
                        lastLocation = g.location
                    }
                    .onEnded { _ in
                        lastLocation = nil
                    }
            )
    }
}
