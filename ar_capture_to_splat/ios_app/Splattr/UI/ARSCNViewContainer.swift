//
//  ARSCNViewContainer.swift
//  SwiftUI bridge that hosts an ARSCNView and binds it to the running
//  ARSession owned by ARCaptureCoordinator. We do NOT render any 3D
//  content — ARSCNView is used purely as a passthrough preview surface.
//

import ARKit
import SceneKit
import SwiftUI

struct ARSCNViewContainer: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = session
        v.automaticallyUpdatesLighting = true
        v.rendersCameraGrain = false
        v.preferredFramesPerSecond = 60
        v.contentMode = .scaleAspectFill
        // We don't show any AR content — clear the scene so SceneKit doesn't
        // do extra work.
        v.scene = SCNScene()
        v.debugOptions = []
        v.showsStatistics = false
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
    }
}
