//
//  VistaViewers.swift
//  Vista
//
//  VISTA TOUCH — our own 3D + AR interaction model (2026-06-11).
//  Field videos showed both stock viewers failing: free-camera 3D let the
//  model drift off-screen and get lost; QuickLook AR dumped a full-size
//  room sideways into the real room.
//
//  3D (Vista3DViewerScreen) — ORBIT-LOCKED RST:
//    The camera always looks at the model. Losing the model is impossible.
//    - 1 finger  : rotate (yaw/pitch), with MOMENTUM that coasts + decays
//    - pinch     : zoom, rubber-band resistance past limits + haptic tick
//    - 2 fingers : translate the look-target, clamped to the model bounds
//    - double tap: spring back to the framed view (+ haptic)
//
//  AR (VistaARViewerScreen) — SPACE-MAPPED placement:
//    - Coaching overlay guides plane discovery ("move your phone")
//    - Auto-places on the first horizontal plane; haptic on landing
//    - ROOMS place as a 1:10 DOLLHOUSE on the floor (a full-size room
//      inside a room is meaningless); objects place real-size
//    - drag = move along the plane, twist = rotate, pinch = resize
//      (RealityKit entity gestures on a collision-shaped model)
//
//  v2 (field video: 3D model ESCAPED the screen; AR model drifted then
//  shot off): 3D physics rewritten to the baked-viewer model Steve
//  certified perfect (OrbitControls-style continuous damping — gestures
//  write a DESIRED state, clamped at write time so the target can never
//  leave the model bounds; camera eases toward it every frame). AR now
//  anchors ONCE at a fixed world transform (auto plane anchors re-target
//  as detection refines = the drift) and translation is ours: drag moves
//  the model only where a floor raycast actually hits (the stock
//  RealityKit translation gesture raycasts past the plane edge and flings
//  entities to infinity = the vanish).
//
//  TOUCH LAB (2026-06-11): debug instrumentation for tuning the feel.
//  Teal dots render under every active finger (visible in screen
//  recordings), and every touch event + orbit-rig state is appended to
//  Documents/vista_touchlab/<tag>_<ts>.jsonl (visible in the Files app,
//  On My iPhone > Vista > vista_touchlab) with millisecond timestamps —
//  so app behavior can be compared against other apps quantitatively.
//

import SwiftUI
import SceneKit
import RealityKit
import ARKit
import UIKit

// MARK: - Touch Lab (debug: finger dots + JSONL event log)

final class TouchLab {
    static let shared = TouchLab()

    private var handle: FileHandle?
    private var t0 = CACurrentMediaTime()
    private var dots: [ObjectIdentifier: CAShapeLayer] = [:]
    private var lastState = ""
    private var lastStateAt: CFTimeInterval = 0

    /// Start a session log. Ends any previous session first.
    func begin(in view: UIView, tag: String) {
        end()
        t0 = CACurrentMediaTime()
        let dir = FileManager.default.urls(for: .documentDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("vista_touchlab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "\(tag)_\(Int(Date().timeIntervalSince1970)).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        write(["ev": "begin", "tag": tag])
    }

    func end() {
        guard handle != nil else { return }
        write(["ev": "end"])
        try? handle?.close()
        handle = nil
        dots.values.forEach { $0.removeFromSuperlayer() }
        dots.removeAll()
    }

    /// Log a touch set + move the finger dots.
    func touches(_ touches: Set<UITouch>, phase: String, in view: UIView) {
        var pts: [[Double]] = []
        for t in touches {
            let p = t.location(in: view)
            pts.append([Double(p.x.rounded()), Double(p.y.rounded())])
            dot(for: t, at: p,
                ended: phase == "end" || phase == "cancel", in: view)
        }
        write(["ev": "touch", "phase": phase, "n": touches.count, "pts": pts])
    }

    /// Log viewer state (orbit rig etc). Throttled to 20 Hz, deduped.
    func state(_ s: String) {
        let now = CACurrentMediaTime()
        guard s != lastState, now - lastStateAt > 0.05 else { return }
        lastState = s
        lastStateAt = now
        write(["ev": "state", "s": s])
    }

    private func write(_ obj: [String: Any]) {
        guard let h = handle else { return }
        var o = obj
        o["t"] = Int((CACurrentMediaTime() - t0) * 1000)
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        h.write(d)
        h.write(Data([0x0A]))
    }

    private func dot(for touch: UITouch, at p: CGPoint,
                     ended: Bool, in view: UIView) {
        let key = ObjectIdentifier(touch)
        if ended {
            dots[key]?.removeFromSuperlayer()
            dots[key] = nil
            return
        }
        let layer: CAShapeLayer
        if let l = dots[key] {
            layer = l
        } else {
            let l = CAShapeLayer()
            l.path = UIBezierPath(
                ovalIn: CGRect(x: -22, y: -22, width: 44, height: 44)).cgPath
            l.fillColor = UIColor(red: 13/255, green: 242/255,
                                  blue: 204/255, alpha: 0.30).cgColor
            l.strokeColor = UIColor(red: 13/255, green: 242/255,
                                    blue: 204/255, alpha: 0.9).cgColor
            l.lineWidth = 2
            view.layer.addSublayer(l)
            dots[key] = l
            layer = l
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = p
        CATransaction.commit()
    }
}

/// SCNView that reports every touch to the Touch Lab (then behaves normally).
final class TouchLabSCNView: SCNView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        TouchLab.shared.touches(touches, phase: "begin", in: self)
        super.touchesBegan(touches, with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        TouchLab.shared.touches(touches, phase: "move", in: self)
        super.touchesMoved(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        TouchLab.shared.touches(touches, phase: "end", in: self)
        super.touchesEnded(touches, with: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        TouchLab.shared.touches(touches, phase: "cancel", in: self)
        super.touchesCancelled(touches, with: event)
    }
}

/// ARView that reports every touch to the Touch Lab (then behaves normally).
final class TouchLabARView: ARView {
    required init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
    }
    dynamic required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        TouchLab.shared.touches(touches, phase: "begin", in: self)
        super.touchesBegan(touches, with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        TouchLab.shared.touches(touches, phase: "move", in: self)
        super.touchesMoved(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        TouchLab.shared.touches(touches, phase: "end", in: self)
        super.touchesEnded(touches, with: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        TouchLab.shared.touches(touches, phase: "cancel", in: self)
        super.touchesCancelled(touches, with: event)
    }
}

// MARK: - 3D: orbit-locked viewer

struct Vista3DViewerScreen: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Vista3DView(url: url)
                .ignoresSafeArea()
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .padding(.top, 18)
            .padding(.trailing, 18)
            VStack {
                Spacer()
                Text("drag rotate · pinch zoom · two-finger move · double-tap reset")
                    .font(.caption2.monospaced())
                    .foregroundStyle(VistaTheme.text2)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(VistaTheme.ink)
    }
}

private struct Vista3DView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Orbit { Orbit() }

    func makeUIView(context: Context) -> SCNView {
        let view = TouchLabSCNView(frame: .zero)
        view.backgroundColor = UIColor(red: 11/255, green: 16/255, blue: 20/255, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true

        let scene = (try? SCNScene(url: url, options: nil)) ?? SCNScene()
        view.scene = scene
        context.coordinator.attach(to: view)
        TouchLab.shared.begin(in: view, tag: "3d")
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) { }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Orbit) {
        TouchLab.shared.end()
    }

    /// Orbit camera rig, OrbitControls-style: gestures write a DESIRED
    /// state (clamped immediately); a permanent display link eases the
    /// rendered state toward it. The model cannot leave the screen.
    final class Orbit: NSObject {
        private weak var scnView: SCNView?
        private let camNode = SCNNode()

        private var center = SCNVector3Zero
        private var radius: Float = 1

        // rendered state (what the camera shows right now)
        private var yaw: Float = 0.7
        private var pitch: Float = 0.3
        private var dist: Float = 3
        private var tx: Float = 0, ty: Float = 0, tz: Float = 0
        // desired state (what gestures ask for; always clamped)
        private var dYaw: Float = 0.7
        private var dPitch: Float = 0.3
        private var dDist: Float = 3
        private var dtx: Float = 0, dty: Float = 0, dtz: Float = 0

        private var home: (yaw: Float, pitch: Float, dist: Float,
                           tx: Float, ty: Float, tz: Float)!
        private var link: CADisplayLink?
        private var limitBuzzed = false

        private let tick = UIImpactFeedbackGenerator(style: .light)
        private let thunk = UIImpactFeedbackGenerator(style: .medium)

        deinit { link?.invalidate() }

        func attach(to view: SCNView) {
            scnView = view
            guard let scene = view.scene else { return }

            let sphere = scene.rootNode.boundingSphere
            center = sphere.center
            radius = max(Float(sphere.radius), 0.05)
            tx = center.x; ty = center.y; tz = center.z
            dtx = tx; dty = ty; dtz = tz
            dist = radius * 2.6
            dDist = dist
            dYaw = yaw; dPitch = pitch
            home = (yaw, pitch, dist, tx, ty, tz)

            camNode.camera = SCNCamera()
            camNode.camera?.automaticallyAdjustsZRange = true
            scene.rootNode.addChildNode(camNode)
            // Render through OUR camera (the original "does nothing" bug).
            view.pointOfView = camNode
            place()

            let rotate = UIPanGestureRecognizer(target: self, action: #selector(onRotate(_:)))
            rotate.maximumNumberOfTouches = 1
            view.addGestureRecognizer(rotate)

            let move = UIPanGestureRecognizer(target: self, action: #selector(onMove(_:)))
            move.minimumNumberOfTouches = 2
            move.maximumNumberOfTouches = 2
            view.addGestureRecognizer(move)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
            view.addGestureRecognizer(pinch)

            let reset = UITapGestureRecognizer(target: self, action: #selector(onReset(_:)))
            reset.numberOfTapsRequired = 2
            view.addGestureRecognizer(reset)

            for g in [rotate, move, pinch, reset] as [UIGestureRecognizer] {
                g.cancelsTouchesInView = false
                g.delaysTouchesBegan = false
                g.delaysTouchesEnded = false
            }

            // Permanent damping loop — the baked-viewer feel: everything
            // eases, nothing snaps, glide continues naturally after release.
            let l = CADisplayLink(target: self, selector: #selector(stepDamping))
            l.add(to: .main, forMode: .common)
            link = l
        }

        @objc private func stepDamping() {
            let k: Float = 0.15
            yaw   += (dYaw - yaw) * k
            pitch += (dPitch - pitch) * k
            dist  += (dDist - dist) * k
            tx += (dtx - tx) * k
            ty += (dty - ty) * k
            tz += (dtz - tz) * k
            place()
        }

        /// Every gesture write lands here: the desired state is ALWAYS legal,
        /// so no gesture combination or cancellation can lose the model.
        private func clampDesired() {
            dPitch = max(-1.45, min(1.45, dPitch))
            let minD = radius * 0.6
            let maxD = radius * 7
            let before = dDist
            dDist = max(minD, min(maxD, dDist))
            if dDist != before {
                if !limitBuzzed { tick.impactOccurred(); limitBuzzed = true }
            } else {
                limitBuzzed = false
            }
            let dx = dtx - center.x
            let dy = dty - center.y
            let dz = dtz - center.z
            let len = sqrtf(dx*dx + dy*dy + dz*dz)
            let maxLen = radius
            if len > maxLen {
                let s = maxLen / len
                dtx = center.x + dx*s
                dty = center.y + dy*s
                dtz = center.z + dz*s
            }
        }

        private func place() {
            let x = tx + dist * cosf(pitch) * sinf(yaw)
            let y = ty + dist * sinf(pitch)
            let z = tz + dist * cosf(pitch) * cosf(yaw)
            camNode.position = SCNVector3(x, y, z)
            camNode.look(at: SCNVector3(tx, ty, tz))
            TouchLab.shared.state(String(
                format: "yaw %.3f pitch %.3f dist %.3f tgt %.2f,%.2f,%.2f",
                yaw, pitch, dist, tx, ty, tz))
        }

        @objc private func onRotate(_ g: UIPanGestureRecognizer) {
            guard let v = scnView else { return }
            switch g.state {
            case .changed:
                let t = g.translation(in: v)
                dYaw   -= Float(t.x) * 0.008
                dPitch += Float(t.y) * 0.008
                g.setTranslation(.zero, in: v)
                clampDesired()
            case .ended:
                // Flick impulse: damping turns it into a natural glide.
                let vel = g.velocity(in: v)
                dYaw   -= Float(vel.x) * 0.0009
                dPitch += Float(vel.y) * 0.0009
                clampDesired()
            default: break
            }
        }

        @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
            guard g.state == .changed, g.scale > 0 else { return }
            dDist /= Float(g.scale)
            g.scale = 1
            clampDesired()
        }

        @objc private func onMove(_ g: UIPanGestureRecognizer) {
            guard let v = scnView, g.state == .changed else { return }
            let t = g.translation(in: v)
            g.setTranslation(.zero, in: v)
            let k = dist * 0.0012
            let right = camNode.worldRight
            let up = camNode.worldUp
            dtx += (-Float(t.x) * right.x + Float(t.y) * up.x) * k
            dty += (-Float(t.x) * right.y + Float(t.y) * up.y) * k
            dtz += (-Float(t.x) * right.z + Float(t.y) * up.z) * k
            clampDesired()
        }

        @objc private func onReset(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            thunk.impactOccurred()
            dYaw = home.yaw
            dPitch = home.pitch
            dDist = home.dist
            dtx = home.tx; dty = home.ty; dtz = home.tz
        }
    }
}

// MARK: - AR: space-mapped placement viewer

struct VistaARViewerScreen: View {
    let url: URL
    let isRoom: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VistaARView(url: url, isRoom: isRoom)
                .ignoresSafeArea()
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .padding(.top, 18)
            .padding(.trailing, 18)
            VStack {
                Spacer()
                Text(isRoom
                     ? "dollhouse on your floor · drag move · twist rotate · pinch size"
                     : "drag move · twist rotate · pinch size")
                    .font(.caption2.monospaced())
                    .foregroundStyle(VistaTheme.text2)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(.black)
    }
}

private struct VistaARView: UIViewRepresentable {
    let url: URL
    let isRoom: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let arView = TouchLabARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        arView.session.run(config)

        // Space mapping: Apple's coaching overlay guides plane discovery.
        let coach = ARCoachingOverlayView()
        coach.session = arView.session
        coach.goal = .horizontalPlane
        coach.activatesAutomatically = true
        coach.delegate = context.coordinator
        coach.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(coach)
        NSLayoutConstraint.activate([
            coach.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            coach.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            coach.topAnchor.constraint(equalTo: arView.topAnchor),
            coach.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
        ])

        TouchLab.shared.begin(in: arView, tag: "ar")

        // Load the model; PLACEMENT is the coordinator's job — once, at a
        // fixed world transform (auto plane anchors re-target as detection
        // refines, which made the model drift away).
        context.coordinator.arView = arView
        context.coordinator.session_setup(isRoom: isRoom, url: url)

        // OUR translation: one-finger drag moves the model only where a
        // floor raycast actually HITS (the stock RealityKit translation
        // gesture raycasts past the plane edge and flings the model to
        // infinity — the "shot off and vanished" bug).
        let drag = UIPanGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.onDrag(_:)))
        drag.maximumNumberOfTouches = 1
        arView.addGestureRecognizer(drag)

        arView.session.delegate = context.coordinator

        // Touch Lab: keep raw touches flowing alongside the gestures so
        // the finger dots survive recognition.
        arView.gestureRecognizers?.forEach {
            $0.cancelsTouchesInView = false
            $0.delaysTouchesBegan = false
            $0.delaysTouchesEnded = false
        }
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) { }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        TouchLab.shared.end()
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate,
                             ARCoachingOverlayViewDelegate {
        weak var arView: ARView?
        private var model: ModelEntity?
        private var placed = false
        private let thunk = UIImpactFeedbackGenerator(style: .medium)

        func session_setup(isRoom: Bool, url: URL) {
            guard let m = try? ModelEntity.loadModel(contentsOf: url) else { return }
            if isRoom { m.scale = SIMD3<Float>(repeating: 0.1) }
            m.generateCollisionShapes(recursive: true)
            model = m
            // Rotation + scale stay RealityKit (stable); translation is ours.
            arView?.installGestures([.rotation, .scale], for: m)
        }

        /// FIXED-WORLD placement: anchor once at the first floor hit under
        /// the screen center. After this the model never re-anchors.
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard !placed, let arView, let model,
                  arView.bounds.width > 10 else { return }
            let centerPt = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            guard let hit = arView.raycast(from: centerPt,
                                           allowing: .estimatedPlane,
                                           alignment: .horizontal).first else { return }
            placed = true
            let anchor = AnchorEntity(world: hit.worldTransform)
            anchor.addChild(model)
            arView.scene.addAnchor(anchor)
            thunk.impactOccurred()   // physical confirmation: it landed
        }

        /// Drag = damped follow toward the floor point under the finger.
        /// No floor hit under the finger -> no movement. Ever.
        @objc func onDrag(_ g: UIPanGestureRecognizer) {
            guard g.state == .changed, placed,
                  let arView, let model else { return }
            let p = g.location(in: arView)
            guard let hit = arView.raycast(from: p,
                                           allowing: .estimatedPlane,
                                           alignment: .horizontal).first else { return }
            let c = hit.worldTransform.columns.3
            let goal = SIMD3<Float>(c.x, c.y, c.z)
            let cur = model.position(relativeTo: nil)
            model.setPosition(cur + (goal - cur) * 0.25, relativeTo: nil)
        }

        func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) { }
    }
}
