//
//  MeshLiveRenderer.swift
//  AR-Layer 2.5 — live "filling-in" mesh overlay during capture.
//
//  ARWorldTrackingConfiguration.sceneReconstruction = .meshWithClassification
//  produces ARMeshAnchors that ARKit refines as the user explores the room.
//  This class is an ARSCNViewDelegate that turns each mesh anchor into a
//  semi-transparent SCNNode in the live preview, classification-coloured so
//  the user sees walls / floor / ceiling / furniture light up as they move.
//
//  The same mesh data is already exported on session end via MeshSerializer
//  → scene_mesh.obj for the laptop. This class is presentation-only — it
//  does NOT influence frame acceptance, capture, or upload. Toggling
//  `isEnabled` to false simply hides every mesh node without affecting any
//  capture state.
//
//  Threading: ARSCNView calls SCNSceneRendererDelegate methods on a
//  background renderer queue. We mark them `nonisolated` and hop to the
//  MainActor before mutating state or touching SceneKit nodes (geometry
//  installation must run on main).
//

import ARKit
import SceneKit
import SwiftUI
import UIKit

@MainActor
final class MeshLiveRenderer: NSObject, ObservableObject, ARSCNViewDelegate {

    /// User-controlled toggle from CaptureView. didSet flips opacity on
    /// every tracked mesh node so toggling is instant and free.
    @Published var isEnabled: Bool = true {
        didSet {
            for node in trackedNodes.values {
                node.opacity = isEnabled ? 1.0 : 0.0
            }
        }
    }

    /// Number of distinct ARMeshAnchors the renderer is currently tracking.
    /// Surfaced in the HUD as a "MESH n" pill so the user can see the
    /// reconstruction grow over time.
    @Published private(set) var anchorCount: Int = 0

    /// anchor.identifier → SceneKit node we own under that anchor.
    /// Cleared when `reset()` is called between sessions.
    private var trackedNodes: [UUID: SCNNode] = [:]

    /// Drop every tracked node and reset state. Call on session restart so
    /// stale meshes from a previous run don't bleed into the new one.
    func reset() {
        for node in trackedNodes.values {
            node.removeFromParentNode()
        }
        trackedNodes.removeAll()
        anchorCount = 0
    }

    // MARK: - ARSCNViewDelegate (ARKit anchor lifecycle)

    nonisolated func renderer(
        _ renderer: SCNSceneRenderer,
        didAdd node: SCNNode,
        for anchor: ARAnchor
    ) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        Task { @MainActor [weak self] in
            self?.installMesh(into: node, from: mesh, isNew: true)
        }
    }

    nonisolated func renderer(
        _ renderer: SCNSceneRenderer,
        didUpdate node: SCNNode,
        for anchor: ARAnchor
    ) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        Task { @MainActor [weak self] in
            self?.installMesh(into: node, from: mesh, isNew: false)
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

    // MARK: - Internal: build / refresh a node's geometry

    private func installMesh(into node: SCNNode, from anchor: ARMeshAnchor, isNew: Bool) {
        let geom = Self.makeGeometry(from: anchor)
        let mat = SCNMaterial()
        mat.diffuse.contents = Self.colorFor(classification: Self.dominantClass(of: anchor))
        // Constant lighting reads cleaner against the camera passthrough.
        mat.lightingModel = .constant
        mat.transparency = 0.32
        mat.isDoubleSided = true
        // Don't write to depth — the AR passthrough will still clip
        // accurately to real-world geometry, but stacked mesh chunks
        // won't z-fight where they overlap.
        mat.writesToDepthBuffer = false
        // Subtle glow on edges
        mat.emission.contents = (Self.colorFor(classification: Self.dominantClass(of: anchor)) as UIColor)
            .withAlphaComponent(0.15)
        geom.materials = [mat]

        node.geometry = geom
        node.opacity = isEnabled ? 1.0 : 0.0
        // ARSCNView already positions `node` at anchor.transform automatically;
        // we don't override it.

        if isNew || trackedNodes[anchor.identifier] == nil {
            trackedNodes[anchor.identifier] = node
            anchorCount = trackedNodes.count
        }
    }

    // MARK: - Geometry conversion (ARMeshAnchor → SCNGeometry)

    /// Wrap the anchor's MTLBuffers in SCNGeometry sources/elements. Cheap:
    /// SceneKit references the same Metal buffers ARKit already maintains;
    /// we don't allocate or copy vertex data.
    private static func makeGeometry(from anchor: ARMeshAnchor) -> SCNGeometry {
        let g = anchor.geometry

        // Vertices (position).
        let vertSource = SCNGeometrySource(
            buffer: g.vertices.buffer,
            vertexFormat: .float3,
            semantic: .vertex,
            vertexCount: g.vertices.count,
            dataOffset: g.vertices.offset,
            dataStride: g.vertices.stride
        )

        // Normals (when present — ARKit provides them).
        var sources: [SCNGeometrySource] = [vertSource]
        if g.normals.count == g.vertices.count {
            let normSource = SCNGeometrySource(
                buffer: g.normals.buffer,
                vertexFormat: .float3,
                semantic: .normal,
                vertexCount: g.normals.count,
                dataOffset: g.normals.offset,
                dataStride: g.normals.stride
            )
            sources.append(normSource)
        }

        // Faces — ARKit emits triangles (indexCountPerPrimitive == 3).
        let element = SCNGeometryElement(
            buffer: g.faces.buffer,
            primitiveType: .triangles,
            primitiveCount: g.faces.count,
            bytesPerIndex: g.faces.bytesPerIndex
        )

        return SCNGeometry(sources: sources, elements: [element])
    }

    // MARK: - Classification → colour

    /// ARMeshClassification raw values per Apple docs:
    ///   0 = none, 1 = wall, 2 = floor, 3 = ceiling, 4 = table, 5 = seat,
    ///   6 = window, 7 = door.
    private static func colorFor(classification: ARMeshClassification) -> UIColor {
        switch classification {
        case .none:    return UIColor.white.withAlphaComponent(0.18)
        case .wall:    return UIColor.systemBlue.withAlphaComponent(0.34)
        case .floor:   return UIColor.systemGreen.withAlphaComponent(0.34)
        case .ceiling: return UIColor.systemOrange.withAlphaComponent(0.30)
        case .table:   return UIColor.systemPurple.withAlphaComponent(0.36)
        case .seat:    return UIColor.systemPink.withAlphaComponent(0.36)
        case .window:  return UIColor.systemTeal.withAlphaComponent(0.42)
        case .door:    return UIColor.systemYellow.withAlphaComponent(0.34)
        @unknown default: return UIColor.white.withAlphaComponent(0.20)
        }
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
            bestCount = n; bestIdx = i
        }
        return ARMeshClassification(rawValue: bestIdx) ?? .none
    }
}
