//
//  MeshExplorerView.swift
//  AR-Layer 2.5 — Gold tier post-scan explorer.
//
//  After the user has built up a textured mesh in CaptureView, this screen
//  lets them WALK AROUND inside that mesh as a first-person 3D environment:
//    - Each ARMeshAnchor becomes a static SCNPhysicsBody (concave-polyhedron
//      collision shape derived from the mesh geometry itself).
//    - The user is a kinematic capsule physics body: manual horizontal
//      velocity for WASD-equivalent movement, vertical velocity driven by
//      SceneKit's physics gravity for proper "stays-on-the-floor" behaviour.
//    - Left half of the screen is a virtual joystick (forward/strafe).
//    - Right half is drag-to-look (yaw + pitch).
//    - A "Jump" button on the right and an "Exit" button up top.
//
//  The mesh data is snapshotted from TexturedMeshRenderer.snapshotForExplorer()
//  so the underlying ARSCNView can keep capturing while the explorer is open.
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
    @State private var lookCumulative: SIMD2<Float> = .zero

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
        LookPad(cumulative: $lookCumulative) { delta in
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
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling2X
        v.preferredFramesPerSecond = 60
        v.allowsCameraControl = false
        v.autoenablesDefaultLighting = false
        v.scene = buildScene()
        // Wire the controller — point camera node at the player capsule.
        controller.attach(scene: v.scene!, sceneView: v)
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // The scene is built once and lives for the explorer's lifetime.
        // Future: support live-refresh while ARKit emits new anchors.
    }

    /// Build a fresh SCNScene from the captured mesh snapshots. Each anchor
    /// becomes a node with a static concave-polyhedron physics body so the
    /// player can walk on the floor and bounce off walls.
    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        scene.physicsWorld.gravity = SCNVector3(0, -9.81, 0)

        // Mesh anchors as static collision geometry.
        for snap in snapshots {
            let node = SCNNode(geometry: snap.geometry)
            node.simdTransform = snap.worldTransform
            // Concave-polyhedron is the right shape for a static room mesh.
            // It supports arbitrary triangle layouts at the cost of some
            // physics CPU; for ~20 anchors of a few thousand triangles
            // each, performance is fine on iPhone Pro.
            let shape = SCNPhysicsShape(
                geometry: snap.geometry,
                options: [
                    .type: SCNPhysicsShape.ShapeType.concavePolyhedron,
                ]
            )
            node.physicsBody = SCNPhysicsBody(type: .static, shape: shape)
            node.physicsBody?.friction = 0.6
            node.physicsBody?.restitution = 0.0
            scene.rootNode.addChildNode(node)
        }

        // Cheap ambient lighting — the textures are pre-baked photos so we
        // mostly just want to *see* them, not relight them.
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 1100
        scene.rootNode.addChildNode(amb)

        return scene
    }
}

// ── First-person controller ──────────────────────────────────────────────────

@MainActor
final class FirstPersonController: ObservableObject {

    @Published private(set) var cameraWorldPosition: SIMD3<Float> = SIMD3(0, 1.6, 0)
    @Published private(set) var lookYaw: Float = 0     // radians, around +Y
    @Published private(set) var lookPitch: Float = 0   // radians, around +X

    private(set) var playerNode: SCNNode = SCNNode()
    private(set) var cameraNode: SCNNode = SCNNode()

    private var displayLink: CADisplayLink?
    private weak var sceneView: SCNView?
    private var lastTickAt: CFTimeInterval = 0

    /// 2D movement vector from the joystick, normalized to [-1, 1].
    /// y > 0 = forward, x > 0 = strafe right.
    private var moveInput: SIMD2<Float> = .zero
    private var pendingJump: Bool = false

    /// Tunable.
    private let walkSpeed: Float = 2.4   // m/s — brisk-walk
    private let jumpVelocity: Float = 4.5

    // Choose a sensible spawn point just inside the captured mesh's centroid,
    // 1.6 m off the floor (eye height for an average adult).
    init() {
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.05
        cameraNode.camera?.zFar = 80
        cameraNode.camera?.fieldOfView = 70
        // Camera sits at "head height" inside the player capsule.
        cameraNode.simdPosition = SIMD3(0, 0.7, 0)

        let capsule = SCNCapsule(capRadius: 0.30, height: 1.7)
        playerNode.geometry = capsule
        playerNode.geometry?.firstMaterial?.transparency = 0.0   // invisible
        playerNode.simdPosition = SIMD3(0, 1.0, 0)
        playerNode.physicsBody = SCNPhysicsBody(
            type: .dynamic,
            shape: SCNPhysicsShape(geometry: capsule, options: nil)
        )
        playerNode.physicsBody?.mass = 70
        playerNode.physicsBody?.friction = 0.0
        playerNode.physicsBody?.angularDamping = 1.0       // never spin
        playerNode.physicsBody?.allowsResting = false
        // Lock rotation so the capsule stays upright under gravity + walls.
        playerNode.physicsBody?.angularVelocityFactor = SCNVector3(0, 0, 0)

        playerNode.addChildNode(cameraNode)
    }

    func attach(scene: SCNScene, sceneView: SCNView) {
        self.sceneView = sceneView
        scene.rootNode.addChildNode(playerNode)
        sceneView.pointOfView = cameraNode
        // Place the player slightly above the rough scene centroid so they
        // fall into view rather than spawning underground.
        let centroid = roughSceneCentroid(scene: scene)
        playerNode.simdPosition = SIMD3(centroid.x, centroid.y + 0.6, centroid.z)
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
        // Sensitivity is tuned for fingertip drag; ~half a screen width
        // sweeps a full 180°.
        let sx: Float = 0.0035
        let sy: Float = 0.0035
        lookYaw -= delta.x * sx
        // Clamp pitch slightly inside [-π/2, π/2] so we never look straight
        // up/down (avoids gimbal-lock visual artifacts).
        lookPitch -= delta.y * sy
        let limit: Float = (.pi / 2) - 0.05
        lookPitch = max(-limit, min(limit, lookPitch))
        applyOrientation()
    }

    func requestJump() { pendingJump = true }

    // MARK: - Per-frame integration

    @objc private func displayTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = max(0.001, min(0.05, Float(now - lastTickAt)))   // clamp
        lastTickAt = now

        // Compute desired horizontal velocity from joystick + look yaw.
        let forward = SIMD3<Float>(-sin(lookYaw), 0, -cos(lookYaw))
        let right = SIMD3<Float>(cos(lookYaw), 0, -sin(lookYaw))
        let horiz = (forward * moveInput.y + right * moveInput.x) * walkSpeed

        // Override XZ velocity, leave Y to physics gravity.
        if let body = playerNode.physicsBody {
            let v = body.velocity
            let vy: Float = pendingJump ? jumpVelocity : Float(v.y)
            body.velocity = SCNVector3(horiz.x, vy, horiz.z)
            pendingJump = false
        }

        // Mirror player position into our camera-position publisher.
        cameraWorldPosition = cameraNode.simdWorldPosition
    }

    private func applyOrientation() {
        let yawQ = simd_quatf(angle: lookYaw, axis: SIMD3(0, 1, 0))
        let pitchQ = simd_quatf(angle: lookPitch, axis: SIMD3(1, 0, 0))
        // Yaw on the player (so collision capsule turns), pitch on camera.
        playerNode.simdOrientation = yawQ
        cameraNode.simdOrientation = pitchQ
    }

    private func roughSceneCentroid(scene: SCNScene) -> SIMD3<Float> {
        var sum = SIMD3<Float>(0, 0, 0)
        var count: Float = 0
        for child in scene.rootNode.childNodes where child.geometry != nil {
            sum += child.simdWorldPosition
            count += 1
        }
        if count == 0 { return SIMD3(0, 1.6, 0) }
        return sum / count
    }
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
                                // Clamp the visual nub to the joystick radius.
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
                                    -Float(clamped.height) / Float(radius)   // y up = forward
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

                // Outer ring
                Circle()
                    .stroke(Color.white.opacity(0.32), lineWidth: 1.4)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(anchor)
                // Inner nub
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
    @Binding var cumulative: SIMD2<Float>
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
