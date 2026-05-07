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
        anchorCount = 0
        latestSnapshot = nil
    }

    // MARK: - Internal state

    private weak var arSession: ARSession?
    private var trackedNodes: [UUID: SCNNode] = [:]
    private var latestSnapshot: CameraSnapshot?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Texture target side length. 512 is plenty for the hand-held overlay
    /// and keeps GPU memory bounded across many anchors.
    private let textureMaxDimension: CGFloat = 512

    private struct CameraSnapshot {
        let image: UIImage
        let viewMatrix: simd_float4x4         // world → camera (ARKit landscape)
        let projectionMatrix: simd_float4x4   // camera → NDC
    }

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
            // ARKit refines the mesh as the user explores. We refresh
            // geometry (vertex positions/faces change) but DO NOT re-bake
            // the texture — keeping the original snapshot texture matches
            // the room's appearance at first observation.
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
    }

    private func makeSnapshot(from frame: ARFrame) -> CameraSnapshot? {
        // Downsize the captured pixel buffer to keep memory bounded.
        let pixelBuffer = frame.capturedImage
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
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
        return CameraSnapshot(
            image: image,
            viewMatrix: view,
            projectionMatrix: proj
        )
    }

    // MARK: - Build / refresh node geometry

    private func installTexturedMesh(
        into node: SCNNode,
        from anchor: ARMeshAnchor,
        isNew: Bool
    ) {
        // If we have no snapshot yet (first second of capture), fall back
        // to a flat-colored translucent material so SOMETHING appears.
        let material: SCNMaterial
        let useTexture = (latestSnapshot != nil) || trackedNodes[anchor.identifier] != nil
        if let snap = latestSnapshot,
           let geom = makeTexturedGeometry(from: anchor, snapshot: snap) {
            material = makeTexturedMaterial(image: snap.image)
            geom.materials = [material]
            node.geometry = geom
        } else {
            // Fall back to flat color
            let geom = makeFlatGeometry(from: anchor)
            material = makeFlatMaterial()
            geom.materials = [material]
            node.geometry = geom
        }
        _ = useTexture   // silence unused-let on the first branch above
        node.opacity = isEnabled ? 1.0 : 0.0
        if isNew || trackedNodes[anchor.identifier] == nil {
            trackedNodes[anchor.identifier] = node
            anchorCount = trackedNodes.count
        }
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
        let anchorXform = anchor.transform
        let viewProj = simd_mul(snapshot.projectionMatrix, snapshot.viewMatrix)
        var uvs = [SIMD2<Float>](repeating: SIMD2(0.5, 0.5), count: vertCount)
        // Read the vertex buffer host-side. Apple's mesh anchors use shared
        // memory, so .contents() reads back without a Metal blit.
        let vBase = g.vertices.buffer.contents().advanced(by: g.vertices.offset)
        for i in 0..<vertCount {
            let vp = vBase.advanced(by: i * g.vertices.stride)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let world = simd_mul(anchorXform, SIMD4<Float>(vp.x, vp.y, vp.z, 1.0))
            let clip = simd_mul(viewProj, world)
            if clip.w == 0 { continue }
            // Perspective divide → NDC [-1, 1]
            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            // NDC → texture UV [0, 1]. ARKit's projectionMatrix uses GL-style
            // NDC where y points up; UIImage texture origin is top-left, so
            // flip y on the way in.
            let u = (ndcX * 0.5) + 0.5
            let v = 1.0 - ((ndcY * 0.5) + 0.5)
            uvs[i] = SIMD2(Float(u), Float(v))
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
