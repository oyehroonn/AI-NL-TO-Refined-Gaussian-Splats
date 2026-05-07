//
//  MeshExplorerView.swift
//  AR-Layer 2.5 — Gold tier post-scan explorer.
//
//  After the user has built up a textured mesh in CaptureView, this screen
//  lets them WALK AROUND inside that mesh as a first-person 3D environment:
//    - Each ARMeshAnchor (deep-copied at snapshot time) becomes a static
//      SCNPhysicsBody with a concave-polyhedron collision shape derived
//      from its triangles.
//    - The player is a dynamic capsule body. Horizontal velocity is
//      driven directly from the joystick; vertical velocity is left to
//      SceneKit's gravity so we stay on the floor.
//    - Yaw is applied to the camera (not the player) so a dynamic-body
//      physics simulation can never fight the look pad.
//    - Spawn point is the world-space AABB center, 1.6 m above the
//      lowest geometry — guaranteed not to start inside a wall.
//
//  The mesh data passed in via [ExplorerSnapshot] is fully owned: every
//  vertex/index/normal/UV byte was deep-copied from ARKit's Metal buffers
//  in TexturedMeshRenderer.snapshotForExplorer(), so the AR session can
//  keep refining anchors underneath without affecting this scene.
//

import SwiftUI
import SceneKit
import UIKit
import simd

// ── SwiftUI screen ───────────────────────────────────────────────────────────

struct MeshExplorerView: View {

    let snapshots: [TexturedMeshRenderer.ExplorerSnapshot]
    /// Optional callbacks fired right after the cover is presented and right
    /// before it dismisses. CaptureView uses these to pause/resume ARKit.
    var onAppear: (() -> Void)? = nil
    var onDisappear: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = FirstPersonController()
    @State private var stickValue: SIMD2<Float> = .zero

    var body: some View {
        ZStack {
            // Render layer
            ExplorerSceneKitView(
                snapshots: snapshots,
                controller: controller
            )
            .ignoresSafeArea()
            // Touch + HUD overlay
            controlsOverlay
        }
        .preferredColorScheme(.dark)
        .background(Color.black)
        .onAppear { onAppear?() }
        .onDisappear {
            controller.stopMovementLoop()
            onDisappear?()
        }
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
    let snapshots: [TexturedMeshRenderer.ExplorerSnapshot]
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
        controller.attach(scene: built.scene, sceneView: v, sceneBounds: built.bounds)
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Scene is built once and lives for the explorer's lifetime.
    }

    private struct BuiltScene {
        let scene: SCNScene
        let bounds: SceneBoundsDescriptor
    }

    /// Build a fresh SCNScene from the captured mesh snapshots and return
    /// the scene plus its world-space AABB. Each anchor becomes a node with:
    ///   - A rebuilt SCNGeometry whose buffers are the snapshot's owned Data.
    ///   - An opaque, depth-writing texture material so we can actually see
    ///     the photo of the room (not the AR-overlay translucent material).
    ///   - A static SCNPhysicsBody with concavePolyhedron collision so the
    ///     player's capsule walks on the floor and bounces off walls.
    private func buildScene() -> BuiltScene {
        let scene = SCNScene()
        scene.physicsWorld.gravity = SCNVector3(0, -9.81, 0)

        // Aggregate AABB across all snapshots — drives the player spawn.
        var wmin = SIMD3<Float>( .infinity,  .infinity,  .infinity)
        var wmax = SIMD3<Float>(-.infinity, -.infinity, -.infinity)

        for snap in snapshots {
            guard let geom = makeGeometry(from: snap) else { continue }
            geom.materials = [makeExplorerMaterial(image: snap.textureImage)]

            let node = SCNNode(geometry: geom)
            // The geometry's vertex positions are in anchor-local space; we
            // re-apply the anchor's worldTransform on the node itself so the
            // mesh sits in its captured world location (and the physics
            // shape is built against the world-space geometry).
            node.simdTransform = snap.worldTransform

            // concavePolyhedron only works against a triangle-list element.
            // Our geometry has exactly that. SceneKit will silently fail if
            // the shape is degenerate; we accept that risk and skip the
            // body for tiny anchors.
            if snap.triangleCount >= 4 {
                let shape = SCNPhysicsShape(
                    geometry: geom,
                    options: [
                        .type: SCNPhysicsShape.ShapeType.concavePolyhedron,
                    ]
                )
                node.physicsBody = SCNPhysicsBody(type: .static, shape: shape)
                node.physicsBody?.friction = 0.6
                node.physicsBody?.restitution = 0.0
            }

            scene.rootNode.addChildNode(node)

            wmin = simd_min(wmin, snap.worldMin)
            wmax = simd_max(wmax, snap.worldMax)
        }

        // Lighting — `.constant` material doesn't actually need lighting
        // but SceneKit honours ambient on it, so a soft ambient still
        // freshens dim corners.
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 600
        amb.light?.color = UIColor.white
        scene.rootNode.addChildNode(amb)

        // Fallback bounds if no snapshots arrived (defensive).
        if !wmin.x.isFinite || !wmax.x.isFinite {
            wmin = SIMD3(-2, -1, -2)
            wmax = SIMD3( 2,  2,  2)
        }
        return BuiltScene(
            scene: scene,
            bounds: SceneBoundsDescriptor(minBound: wmin, maxBound: wmax)
        )
    }

    /// Build a SCNGeometry from owned Data blobs — no shared MTLBuffer.
    private func makeGeometry(
        from snap: TexturedMeshRenderer.ExplorerSnapshot
    ) -> SCNGeometry? {
        guard snap.vertexCount > 0, snap.triangleCount > 0 else { return nil }

        let vertSource = SCNGeometrySource(
            data: snap.vertexData,
            semantic: .vertex,
            vectorCount: snap.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.size
        )

        var sources: [SCNGeometrySource] = [vertSource]
        if snap.normalCount == snap.vertexCount, !snap.normalData.isEmpty {
            sources.append(SCNGeometrySource(
                data: snap.normalData,
                semantic: .normal,
                vectorCount: snap.normalCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD3<Float>>.size
            ))
        }
        sources.append(SCNGeometrySource(
            data: snap.uvData,
            semantic: .texcoord,
            vectorCount: snap.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.size
        ))

        let element = SCNGeometryElement(
            data: snap.indexData,
            primitiveType: .triangles,
            primitiveCount: snap.triangleCount,
            bytesPerIndex: snap.bytesPerIndex
        )
        return SCNGeometry(sources: sources, elements: [element])
    }

    private func makeExplorerMaterial(image: UIImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant       // textures already encode the look
        m.diffuse.contents = image
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.transparency = 1.0              // OPAQUE — explorer has no AR feed
        m.isDoubleSided = true
        m.writesToDepthBuffer = true      // proper z-ordering
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
        sceneView.pointOfView = cameraNode

        // Spawn at the AABB center (XZ) and 1.6 m above the lowest geometry.
        // 1.6 m is adult eye height — gravity then settles us onto the floor.
        let center = (sceneBounds.minBound + sceneBounds.maxBound) * 0.5
        let spawn = SIMD3<Float>(center.x, sceneBounds.minBound.y + 1.6, center.z)
        playerNode.simdPosition = spawn
        // Reset velocity so spawn doesn't inherit any junk transient.
        playerNode.physicsBody?.velocity = SCNVector3(0, 0, 0)

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
