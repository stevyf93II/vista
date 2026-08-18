//
//  RoomSceneViewer.swift
//  Vista
//
//  3D-only library viewer for Room scans. Orbit controls + explicit X dismiss.
//  No AR button -- Steve requested removal until the AR navigation is more
//  user-friendly. Object scans continue to use QuickLook (which includes AR).
//

import SwiftUI
import SceneKit

struct RoomSceneViewer: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            SCNViewWrapper(url: url)
                .ignoresSafeArea()

            HStack(alignment: .top) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.85))
                    Text("3D view · drag to orbit, pinch to zoom")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
}

private struct SCNViewWrapper: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60

        loadScene(into: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        // Reload if the URL changes (shouldn't happen mid-session, but safe).
        if view.scene == nil {
            loadScene(into: view)
        }
    }

    private func loadScene(into view: SCNView) {
        guard let scene = try? SCNScene(
            url: url,
            options: [
                .checkConsistency: false,
                .convertToYUp: true,
            ]
        ) else {
            return
        }
        view.scene = scene

        // Frame the scene by adding a dedicated camera looking at the bbox
        // center from a distance proportional to the largest extent.
        let root = scene.rootNode
        let bbox = root.boundingBox
        let centerX = (bbox.min.x + bbox.max.x) * 0.5
        let centerY = (bbox.min.y + bbox.max.y) * 0.5
        let centerZ = (bbox.min.z + bbox.max.z) * 0.5
        let extentX = bbox.max.x - bbox.min.x
        let extentY = bbox.max.y - bbox.min.y
        let extentZ = bbox.max.z - bbox.min.z
        let maxExtent = max(extentX, max(extentY, extentZ))
        let distance = max(0.5, maxExtent * 1.6)

        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = max(200, Double(maxExtent) * 8.0)
        camera.fieldOfView = 55

        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(centerX,
                                      centerY + extentY * 0.3,
                                      centerZ + distance)
        camNode.look(at: SCNVector3(centerX, centerY, centerZ))
        scene.rootNode.addChildNode(camNode)
        view.pointOfView = camNode
    }
}
