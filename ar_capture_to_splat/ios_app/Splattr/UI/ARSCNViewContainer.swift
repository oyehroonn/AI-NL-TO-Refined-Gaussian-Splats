//
//  ARSCNViewContainer.swift
//  SwiftUI bridge that hosts an ARSCNView and binds it to the running
//  ARSession owned by ARCaptureCoordinator.
//
//  AR-Layer 2.5 hook: an optional `ARSCNViewDelegate` is forwarded to the
//  hosted ARSCNView. CaptureView passes a `MeshLiveRenderer` so the live
//  preview shows sceneReconstruction mesh anchors as a translucent
//  classification-coloured overlay (the "filling-in" effect). Pass nil to
//  keep the view as a pure passthrough surface.
//

import ARKit
import SceneKit
import SwiftUI

struct ARSCNViewContainer: UIViewRepresentable {
    let session: ARSession
    /// Optional ARSCNView delegate. Used by AR-Layer 2.5 for live mesh
    /// rendering; nil leaves the view a plain camera passthrough.
    var delegate: ARSCNViewDelegate?

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = session
        v.automaticallyUpdatesLighting = true
        v.rendersCameraGrain = false
        v.preferredFramesPerSecond = 60
        v.contentMode = .scaleAspectFill
        v.scene = SCNScene()
        v.debugOptions = []
        v.showsStatistics = false
        v.delegate = delegate
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
        // Forward a delegate change — SwiftUI may rebuild the parent
        // before the renderer is ready, so we tolerate nil → non-nil.
        if (uiView.delegate as AnyObject?) !== (delegate as AnyObject?) {
            uiView.delegate = delegate
        }
    }
}
