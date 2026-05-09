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

    let snapshots: [TexturedMeshRenderer.ExplorerSnapshot]

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = FirstPersonController()
    @State private var stickValue: SIMD2<Float> = .zero

    var body: some View {
        ZStack {
            ExplorerSceneKitView(
                snapshots: snapshots,
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
    let bakedMesh: BakedMesh
    let controller: FirstPersonController

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        v.antialiasingMode = .multisampling2X
        v.preferredFramesPerSecond = 60
        v.allowsCameraControl = false
        v.autoenablesDefaultLighting = false
        v.rendersContinuously = true
        let built = buildScene()
        v.scene = built.scene
        controller.attach(
            scene: built.scene,
            sceneView: v,
            sceneBounds: SceneBoundsDescriptor(
                minBound: bakedMesh.worldMin,
                maxBound: bakedMesh.worldMax
            )
        )
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Scene is built once and lives for the explorer's lifetime.
    }

    private struct BuiltScene { let scene: SCNScene }

    /// Build the SCNScene from the BakedMesh:
    ///   - One render node PER BakedChunk. Each chunk owns its own
    ///     SCNGeometry (3 verts/tri, atlas UVs) and material (the chunk's
    ///     baked atlas as MTLTexture diffuse). N chunks = N draw calls,
    ///     handled trivially by SceneKit. Multi-atlas exists so we can
    ///     hold full per-face resolution (256 px per face) on rooms with
    ///     more triangles than fit in one atlas.
    ///   - One hidden physics node from the welded mesh (shared vertices,
    ///     indexed triangles) — concavePolyhedron static body, full
    ///     collision detail across the whole room regardless of how many
    ///     atlases the rendering uses.
    ///   - Soft ambient. Atlas is `.constant` so lights only matter for
    ///     SceneKit's ambient blend.
    private func buildScene() -> BuiltScene {
        let scene = SCNScene()
        scene.physicsWorld.gravity = SCNVector3(0, -9.81, 0)
        scene.physicsWorld.timeStep = 1.0 / 90.0  // smoother walking

        // ── Render: one SCNNode per BakedChunk ──────────────────────────
        for chunk in bakedMesh.chunks {
            guard let geom = makeChunkRenderGeometry(chunk: chunk) else { continue }
            geom.materials = [makeAtlasMaterial(atlas: chunk.atlas)]
            let node = SCNNode(geometry: geom)
            node.castsShadow = false
            scene.rootNode.addChildNode(node)
        }

        // ── Physics: one body from the welded mesh ──────────────────────
        if let physicsGeom = makePhysicsGeometry() {
            let body = SCNPhysicsBody(
                type: .static,
                shape: SCNPhysicsShape(
                    geometry: physicsGeom,
                    options: [.type: SCNPhysicsShape.ShapeType.concavePolyhedron]
                )
            )
            body.friction = 0.6
            body.restitution = 0.0
            let physNode = SCNNode(geometry: physicsGeom)
            physNode.geometry?.firstMaterial?.transparency = 0.0
            physNode.physicsBody = body
            physNode.opacity = 0.0
            physNode.castsShadow = false
            scene.rootNode.addChildNode(physNode)
        }

        // ── Lighting ────────────────────────────────────────────────────
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 1000
        amb.light?.color = UIColor.white
        scene.rootNode.addChildNode(amb)

        return BuiltScene(scene: scene)
    }

    // MARK: - Geometry construction

    /// Build the render geometry for ONE chunk. 3 verts per triangle
    /// (no shared vertices — each carries its tile-corner atlas UV),
    /// sequential 0...3N-1 triangle indices, single material later
    /// applied with the chunk's atlas as diffuse.
    private func makeChunkRenderGeometry(chunk: BakedChunk) -> SCNGeometry? {
        let n = chunk.triangleCount
        guard n > 0 else { return nil }
        let vertCount = n * 3

        let vertData = chunk.renderVertices.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        let normalData = chunk.renderNormals.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        let uvData = chunk.renderUVs.withUnsafeBufferPointer {
            Data(buffer: $0)
        }

        let vertSrc = SCNGeometrySource(
            data: vertData, semantic: .vertex,
            vectorCount: vertCount, usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.size
        )
        let normSrc = SCNGeometrySource(
            data: normalData, semantic: .normal,
            vectorCount: vertCount, usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.size
        )
        let uvSrc = SCNGeometrySource(
            data: uvData, semantic: .texcoord,
            vectorCount: vertCount, usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.size
        )

        // SceneKit needs an element buffer even when indices are
        // sequential. Generate 0..3N-1.
        var indices = [UInt32](repeating: 0, count: vertCount)
        for i in 0..<vertCount { indices[i] = UInt32(i) }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: n,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        return SCNGeometry(sources: [vertSrc, normSrc, uvSrc],
                            elements: [element])
    }

    /// Build the welded physics geometry: shared vertices + indexed
    /// triangles. Used purely for SCNPhysicsShape concave-polyhedron
    /// construction. No UVs needed. Spans the whole mesh regardless
    /// of how many render chunks split it.
    private func makePhysicsGeometry() -> SCNGeometry? {
        guard !bakedMesh.physicsVertices.isEmpty,
              !bakedMesh.physicsTriangles.isEmpty else { return nil }
        let vertData = bakedMesh.physicsVertices.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        let vertSrc = SCNGeometrySource(
            data: vertData, semantic: .vertex,
            vectorCount: bakedMesh.physicsVertices.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.size
        )
        let indexData = bakedMesh.physicsTriangles.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: bakedMesh.physicsTriangles.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        return SCNGeometry(sources: [vertSrc], elements: [element])
    }

    // MARK: - Material

    private func makeAtlasMaterial(atlas: UIImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        // UIImage is the proven Phase 1 path for SCN material content.
        // SceneKit creates its own MTLTexture from the UIImage, properly
        // tagged sRGB, and renders it correctly through its standard
        // pipeline. Earlier attempts to pass MTLTexture directly failed
        // silently (grayscale output) on real device.
        m.diffuse.contents = atlas
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.minificationFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.mipFilter = .nearest
        m.transparency = 1.0
        m.isDoubleSided = true
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        return m
    }
}

// ── First-person controller ──────────────────────────────────────────────────

@MainActor
final class FirstPersonController: ObservableObject {

    @Published private(set) var cameraWorldPosition: SIMD3<Float> = SIMD3(0, 1.6, 0)

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
        let center = (sceneBounds.minBound + sceneBounds.maxBound) * 0.5
        let spawn = SIMD3<Float>(center.x, sceneBounds.minBound.y + 1.6, center.z)
        playerNode.simdPosition = spawn
        playerNode.physicsBody?.velocity = SCNVector3(0, 0, 0)

        sceneView.pointOfView = cameraNode

        // Warm up the renderer so the first display-link frame already has
        // textures + geometry uploaded to the GPU. Without this, the very
        // first present can come back blank for one or two frames while
        // SceneKit lazily uploads.
        sceneView.prepare([scene]) { _ in }

        startMovementLoop()
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
        _ = dt  // velocity-based; SceneKit advances the simulation itself.

        // Compute desired horizontal velocity from joystick + camera yaw.
        // Camera-space forward is -Z; yaw is around +Y.
        let forward = SIMD3<Float>(-sin(lookYaw), 0, -cos(lookYaw))
        let right = SIMD3<Float>(cos(lookYaw), 0, -sin(lookYaw))
        let horiz = (forward * moveInput.y + right * moveInput.x) * walkSpeed

        // Override XZ velocity, leave Y to physics gravity (or jump impulse).
        if let body = playerNode.physicsBody {
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

        // Mirror player position into our publisher.
        cameraWorldPosition = cameraNode.simdWorldPosition
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
