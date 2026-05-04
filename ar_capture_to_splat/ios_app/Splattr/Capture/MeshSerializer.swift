//
//  MeshSerializer.swift
//  AR-Layer 3 — sceneReconstruction snapshot → Wavefront OBJ.
//
//  ARWorldTrackingConfiguration.sceneReconstruction = .meshWithClassification
//  produces ARMeshAnchors that ARKit updates over time. We don't accumulate
//  every update — instead, at session end we snapshot all currently-active
//  mesh anchors via `arSession.currentFrame.anchors` and write a single OBJ.
//
//  Each ARMeshAnchor has its own local coordinate frame; we transform the
//  vertices into world space using `anchor.transform` so the OBJ is
//  reconstruction-ready (matches the `world` frame used by camera_transform_world
//  in the manifest).
//
//  We also emit:
//    - per-vertex normals when ARKit provides them
//    - one `g class_<n>` group per vertex classification when the mesh has them
//
//  Format choice: OBJ — text, easy to inspect, one of the formats the
//  laptop server's `mesh` slot already accepts (see CAPTURE_PROTOCOL.md §2).
//

import ARKit
import Foundation
import simd

@MainActor
enum MeshSerializer {

    /// Snapshot every ARMeshAnchor on `session.currentFrame` and write a
    /// single OBJ to `url`. Returns true when at least one face was written.
    static func writeOBJ(from session: ARSession, to url: URL) -> Bool {
        guard let frame = session.currentFrame else { return false }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        if meshAnchors.isEmpty { return false }

        var lines: [String] = []
        lines.reserveCapacity(64)
        lines.append("# Splattr scene mesh — ARKit sceneReconstruction snapshot")
        lines.append("# anchors=\(meshAnchors.count)")
        lines.append("# format: world-space vertices, optional normals, " +
                     "groups by classification when present")

        var totalFaces = 0
        var vertexBase = 1   // OBJ indices are 1-based

        for (anchorIdx, anchor) in meshAnchors.enumerated() {
            let geom = anchor.geometry
            let xform = anchor.transform

            // ----- vertices -----
            let vCount = geom.vertices.count
            let vBuf = geom.vertices.buffer
            let vStride = geom.vertices.stride
            let vOffset = geom.vertices.offset
            let vBase = vBuf.contents().advanced(by: vOffset)

            for i in 0..<vCount {
                let p = vBase.advanced(by: i * vStride)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world = xform * SIMD4<Float>(p.x, p.y, p.z, 1.0)
                lines.append(String(format: "v %.6f %.6f %.6f",
                                    world.x, world.y, world.z))
            }

            // ----- normals (optional) -----
            let nCount = geom.normals.count
            if nCount == vCount {
                let nBuf = geom.normals.buffer
                let nStride = geom.normals.stride
                let nOffset = geom.normals.offset
                let nBase = nBuf.contents().advanced(by: nOffset)
                let R = simd_float3x3(
                    SIMD3<Float>(xform.columns.0.x, xform.columns.0.y, xform.columns.0.z),
                    SIMD3<Float>(xform.columns.1.x, xform.columns.1.y, xform.columns.1.z),
                    SIMD3<Float>(xform.columns.2.x, xform.columns.2.y, xform.columns.2.z)
                )
                for i in 0..<nCount {
                    let n = nBase.advanced(by: i * nStride)
                        .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    let worldN = simd_normalize(R * n)
                    lines.append(String(format: "vn %.6f %.6f %.6f",
                                        worldN.x, worldN.y, worldN.z))
                }
            }

            // ----- faces (with optional classification grouping) -----
            let faceCount = geom.faces.count
            let primSize = geom.faces.indexCountPerPrimitive
            // Mesh anchors emit triangles (3) per Apple docs.
            guard primSize == 3, faceCount > 0 else {
                vertexBase += vCount
                continue
            }
            let fBuf = geom.faces.buffer.contents()
            let bytesPerIndex = geom.faces.bytesPerIndex

            // Try to read per-face classification, when ARKit provides it.
            var classifications: [UInt8]? = nil
            if let cls = geom.classification, cls.count == faceCount {
                let cBuf = cls.buffer.contents().advanced(by: cls.offset)
                var arr: [UInt8] = []
                arr.reserveCapacity(faceCount)
                for i in 0..<faceCount {
                    arr.append(cBuf.advanced(by: i * cls.stride)
                                .assumingMemoryBound(to: UInt8.self).pointee)
                }
                classifications = arr
            }

            // Group consecutive faces of the same classification under one
            // `g class_<n>` so downstream tools can split the mesh by room
            // surface type (wall/floor/ceiling/etc.).
            var lastClass: UInt8 = 255
            lines.append("g anchor_\(anchorIdx)")
            for fi in 0..<faceCount {
                let cls = classifications?[fi] ?? 255
                if cls != lastClass {
                    lines.append("g anchor_\(anchorIdx)_class_\(Int(cls))")
                    lastClass = cls
                }
                let i0 = readIndex(buffer: fBuf,
                                   faceIdx: fi, vertexInFace: 0,
                                   bytesPerIndex: bytesPerIndex)
                let i1 = readIndex(buffer: fBuf,
                                   faceIdx: fi, vertexInFace: 1,
                                   bytesPerIndex: bytesPerIndex)
                let i2 = readIndex(buffer: fBuf,
                                   faceIdx: fi, vertexInFace: 2,
                                   bytesPerIndex: bytesPerIndex)
                lines.append("f \(vertexBase + i0) \(vertexBase + i1) \(vertexBase + i2)")
                totalFaces += 1
            }

            vertexBase += vCount
        }

        guard totalFaces > 0 else { return false }

        do {
            let body = lines.joined(separator: "\n") + "\n"
            try body.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[MeshSerializer] write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Pull a face-index out of the packed buffer, supporting both 16- and
    /// 32-bit index types (ARKit currently emits UInt32 but Apple's docs
    /// don't guarantee it).
    private static func readIndex(
        buffer: UnsafeRawPointer,
        faceIdx: Int,
        vertexInFace: Int,
        bytesPerIndex: Int
    ) -> Int {
        let primSize = 3
        let elemIdx = faceIdx * primSize + vertexInFace
        let byteOffset = elemIdx * bytesPerIndex
        switch bytesPerIndex {
        case 2:
            return Int(buffer.advanced(by: byteOffset)
                .assumingMemoryBound(to: UInt16.self).pointee)
        case 4:
            return Int(buffer.advanced(by: byteOffset)
                .assumingMemoryBound(to: UInt32.self).pointee)
        default:
            return 0
        }
    }
}
