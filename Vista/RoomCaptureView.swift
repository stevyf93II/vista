//
//  RoomCaptureView.swift
//  Vista
//
//  Phase 5.0 prep (2026-06-07): after a Room scan, also export a
//  bake-ready bundle to Documents/vista_bundles/<scan_name>/ so the
//  Lenovo can pull it via iMazing / Apple Devices.
//
//  Phase 6 (2026-06-09): roadmap #2 piece 3 — "Bake in Vista cloud" uploads the
//  bundle to Modal (chunked), polls for the textured GLB, and opens it in the
//  in-app three.js viewer (GLBViewerScreen). The older "Share via Vista cloud"
//  (USDZ -> Render) path is untouched.
//
//  2026-06-10: custom coverage overlay replaces the system
//  .showSceneUnderstanding debug mesh (invisible on bright surfaces).
//  v4 "MESHING": coverage renders as the actual LiDAR triangle mesh in
//  glowing WIREFRAME lines (Steve's point-cloud/wireframe reference look),
//  not a solid veil. Trick: every triangle gets its own barycentric UVs
//  mapped to a tiny procedural edge-lines texture — no Metal file, no
//  CustomMaterial, plain UnlitMaterial. Fresh mesh appears bright cyan and
//  cools/darkens into settled magenta lines over ~1.2s; the one-shot flash
//  logic from v3 is unchanged (flash only on first appearance or real
//  geometry growth — no strobe). If texture creation ever fails, falls
//  back to the v3.1 solid veil automatically.
//  v5 (build 44 field report: "can't see it" + Steve's brand video):
//  palette is now the VISTA SIGNATURE — fresh surfaces land HOT ORANGE and
//  cool into a glowing TEAL mesh; texture gains a faint translucent glow
//  FILL (16%) so captured surfaces read as a hologram, not just lines; and
//  lines thickened 6% -> 10% of texture so mipmapping can't fade them out
//  at room distance (the build-44 invisibility).
//  v6 (same build): PERSISTENT ORANGE EDGE ACCENTS — the brand video's
//  glowing room corners. CPU crease detection (no Metal): any mesh edge
//  whose two neighboring triangles bend > ~60 deg (wall-wall, wall-floor,
//  furniture silhouettes) is drawn as a thin orange ribbon, lifted 3mm off
//  the surface, double-sided. Chunk-boundary edges are deliberately
//  EXCLUDED (they're tiling seams mid-wall, not real corners). Edge
//  entities live beside the wire entities, same rebuild throttle.
//  v6.1 (build 45 field report): crease gate tightened to ~75+ deg with
//  3cm min edges (60 deg painted orange over couch folds and clutter);
//  rebuilds now SKIP unchanged chunks and throttle 2.5s (the 400-frame
//  camera lag was 40+ chunks rebuilding heavy meshes every 0.8s).
//  v6.2 (field report: ARKit tracking reset at 30 chunks -> anchors went
//  0 -> restored, but HALF THE OVERLAY never came back): after a
//  relocalization ARKit doesn't reliably re-announce restored anchors, so
//  overlays that existed before the reset were never rebuilt. Self-heal
//  reconcile pass (1Hz, max 8 rebuilds/tick): any live mesh anchor with no
//  overlay entity is rebuilt SETTLED (teal, no fake orange flash); any
//  overlay whose anchor is gone for good is removed (no ghosts).
//  v6.3: "Bake last scan" button on the idle Room tab — killing the app
//  mid-upload stranded the surviving bundle with no UI path back to it
//  (Retry only existed in the .failed phase, which a restart wipes).
//
//  Earlier history:
//  - Phase 2 visibility (f995783): TSDF mesh -> room.usdz primary in Library,
//    Phase 1 textured USDZ kept as room_phase1.usdz fallback.
//  - Phase 1 (2d0ddb5): per-ARFrame snapshot + disk dump.
//

import SwiftUI
import ARKit
import RealityKit
import SceneKit
import simd
import UIKit
import CoreImage

struct RoomCaptureView: View {
    @AppStorage("renderBaseURL") private var renderBaseURL: String = ""
    @AppStorage("uploadToken") private var uploadToken: String = ""
    @AppStorage("slugPrefix") private var slugPrefix: String = "vista-"

    @State private var phase: Phase = .idle
    @State private var showCaptureSheet = false
    // sheet(item:) instead of sheet(isPresented:) + optional URL — the bool/optional
    // pair raced: the sheet body could evaluate while viewerURL was still nil,
    // `if let` failed, and the user got an EMPTY dark sheet (the "grey screen").
    // An item-based sheet cannot present without its payload.
    @State private var viewerItem: ViewerItem? = nil

    private struct ViewerItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    enum Phase {
        case idle
        case exporting
        case ready(URL)
        case uploading
        case uploaded(UploadResult)
        case baking(String)
        case baked(URL)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 20)
                    Image(systemName: "house.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.tint)
                    Text("Room Capture")
                        .font(.title).fontWeight(.semibold)
                    Text("Walk slowly around the room. LiDAR builds the mesh in real time; per-frame depth + RGB + camera pose are saved as inputs for TSDF fusion. New surfaces flash orange and cool into the glowing teal Vista mesh — sweep until walls, floor AND CEILING are meshed. Each scan also writes a bake-ready bundle to Documents/vista_bundles/.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                    Divider().padding(.horizontal, 40)
                    if !isLidarSupported { unsupportedNotice } else { actionArea }
                    Spacer()
                }
            }
            .navigationTitle("Room")
        }
        .fullScreenCover(isPresented: $showCaptureSheet) {
            CaptureSheet(
                onFinish: handleFinishedScan,
                onCancel: { showCaptureSheet = false },
                onError: handleScanError
            )
        }
        .sheet(item: $viewerItem) { item in
            GLBViewerScreen(glbURL: item.url)
        }
    }

    private var isLidarSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    private var unsupportedNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.title2)
            Text("This device does not support LIDAR scene reconstruction.\nRequires iPhone 12 Pro or later.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var actionArea: some View {
        switch phase {
        case .idle:
            Button { showCaptureSheet = true } label: {
                Label("Start Room Scan", systemImage: "arkit").font(.headline)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            // v6.3: a bundle survives until its bake SUCCEEDS — so after an
            // app kill/restart the last scan is still bakeable from here.
            if BundleExporter.latestBundleDir() != nil {
                Button { Task { await bake() } } label: {
                    Label("Bake last scan in Vista cloud",
                          systemImage: "cube.transparent")
                }
                .buttonStyle(.bordered)
            }
            if uploadToken.isEmpty {
                Text("Tip: set Upload Token in Settings to enable optional sharing.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        case .exporting:
            VStack(spacing: 8) {
                ProgressView()
                Text("Building TSDF mesh + bake bundle...")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ready(let url):
            VStack(spacing: 12) {
                Label("Saved to Library", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
                Text(url.lastPathComponent).font(.caption2.monospaced()).foregroundStyle(.secondary)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int {
                    Text(byteSizeString(size)).font(.caption2).foregroundStyle(.secondary)
                }
                Text("Open the Library tab to view in 3D. Bake bundle is in Documents/vista_bundles/.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Button { Task { await bake() } } label: {
                    Label("Bake in Vista cloud (3D)", systemImage: "cube.transparent")
                }
                .buttonStyle(.borderedProminent)
                Button { Task { await upload(url) } } label: {
                    Label("Share via Vista cloud", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.bordered).disabled(uploadToken.isEmpty)
                if uploadToken.isEmpty {
                    Text("Set Upload Token in Settings to share")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Button("Done") { phase = .idle }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
        case .uploading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Uploading USDZ...").font(.caption).foregroundStyle(.secondary)
            }
        case .uploaded(let result):
            VStack(alignment: .leading, spacing: 6) {
                Label("Shared", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
                Text(result.filename).font(.caption2).foregroundStyle(.secondary)
                Text(result.url).font(.caption2.monospaced()).foregroundStyle(.tint).textSelection(.enabled)
                Button("Scan another room") { phase = .idle }.font(.caption).padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding().background(Color(.secondarySystemBackground)).cornerRadius(10)
            .padding(.horizontal, 24)
        case .baking(let status):
            VStack(spacing: 8) {
                ProgressView()
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Text("Cloud bake runs ~5–10 min. Keep the app open and online.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        case .baked(let url):
            VStack(spacing: 12) {
                Label("Baked", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
                Text(url.lastPathComponent).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Button { viewerItem = ViewerItem(url: url) } label: {
                    Label("View in 3D", systemImage: "rotate.3d")
                }
                .buttonStyle(.borderedProminent)
                Button("Done") { phase = .idle }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
        case .failed(let msg):
            VStack(spacing: 8) {
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red).font(.caption)
                Text(msg).font(.caption2.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if BundleExporter.latestBundleDir() != nil {
                    Button { Task { await bake() } } label: {
                        Label("Retry bake", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Start over") { phase = .idle }.font(.caption)
            }
            .padding(.horizontal, 24)
        }
    }

    private func byteSizeString(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1024
        return String(format: "%.0f KB", kb)
    }

    private func handleFinishedScan(_ tempURL: URL) {
        showCaptureSheet = false
        do {
            let persisted = try ScansStorage.saveCopy(of: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            phase = .ready(persisted)
        } catch {
            phase = .ready(tempURL)
        }
    }

    private func handleScanError(_ error: Error) {
        showCaptureSheet = false
        phase = .failed(error.localizedDescription)
    }

    private func upload(_ url: URL) async {
        phase = .uploading
        do {
            let suffix = String(Int.random(in: 1000...9999))
            let slug = "\(slugPrefix)room-\(suffix)"
            let service = try UploadService.fromSettings(baseURLString: renderBaseURL, token: uploadToken)
            let result = try await service.uploadFile(url, slug: slug)
            phase = .uploaded(result)
        } catch let err as UploadError {
            phase = .failed(err.errorDescription ?? "\(err)")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Roadmap #2 piece 3: upload the just-finished scan's bake bundle to Modal
    /// (chunked), poll for the textured GLB, and open it in the in-app viewer.
    private func bake() async {
        guard let bundleDir = BundleExporter.latestBundleDir() else {
            phase = .failed("No bake bundle found for this scan.")
            return
        }
        // Keep the screen awake for the whole upload+bake: phone sleep
        // suspends URLSession and kills the bake mid-upload.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        phase = .baking("Preparing…")
        do {
            let uploader = BakeUploader()
            let glb = try await uploader.uploadAndBake(bundleDir: bundleDir) { stage in
                let text = Self.stageText(stage)
                Task { @MainActor in phase = .baking(text) }
            }
            phase = .baked(glb)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func stageText(_ stage: BakeUploader.Stage) -> String {
        switch stage {
        case .zipping:
            return "Zipping bundle…"
        case .uploading(let sent, let total):
            if total > 0 {
                let pct = Int(Double(sent) / Double(total) * 100)
                return "Uploading \(pct)%"
            }
            return "Uploading…"
        case .finishing:
            return "Assembling on server…"
        case .baking:
            return "Baking room…"
        case .downloading:
            return "Downloading model…"
        }
    }
}

/// Per-frame entry kept in RAM during a scan — drives the Phase 1 USDZ texture path.
struct CapturedFrame {
    let id: UUID
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageWidth: Int
    let imageHeight: Int
    let imageURL: URL
}

// MARK: - Capture sheet

private struct CaptureSheet: View {
    let onFinish: (URL) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    @State private var arViewRef: ARView?
    @State private var isProcessing = false
    @State private var meshCount: Int = 0
    @State private var frameCount: Int = 0

    var body: some View {
        ZStack {
            ARMeshRepresentable(
                onViewReady: { view in arViewRef = view },
                onCoverageUpdate: { mc, fc in meshCount = mc; frameCount = fc }
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button { onCancel() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("\(meshCount) chunks").font(.caption.monospaced())
                        Text("\(frameCount) frames").font(.caption2.monospaced()).opacity(0.85)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    Spacer()
                    Button {
                        guard !isProcessing, let view = arViewRef else { return }
                        isProcessing = true
                        Task {
                            do {
                                let url = try await ARMeshExporter.export(arView: view)
                                onFinish(url)
                            } catch {
                                onError(error)
                            }
                        }
                    } label: {
                        if isProcessing {
                            ProgressView().tint(.white)
                                .padding(.horizontal, 24).padding(.vertical, 8)
                                .background(.black.opacity(0.5), in: Capsule())
                        } else {
                            Text("Done").font(.headline).foregroundStyle(.white)
                                .padding(.horizontal, 24).padding(.vertical, 8)
                                .background(.blue, in: Capsule())
                        }
                    }
                }
                .padding()
                Spacer()
            }
        }
    }
}

private struct ARMeshRepresentable: UIViewRepresentable {
    let onViewReady: (ARView) -> Void
    let onCoverageUpdate: (Int, Int) -> Void

    func makeCoordinator() -> ARMeshCoordinator {
        ARMeshCoordinator(onCoverageUpdate: onCoverageUpdate)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth,
                                                                 .smoothedSceneDepth]) {
            config.frameSemantics.insert([.sceneDepth, .smoothedSceneDepth])
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        view.session.delegate = context.coordinator
        view.session.run(config)
        // Custom coverage overlay (replaces .showSceneUnderstanding, whose
        // default coloring is invisible on bright/white surfaces).
        context.coordinator.attachOverlay(to: view)
        DispatchQueue.main.async { onViewReady(view) }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) { }
    static func dismantleUIView(_ uiView: ARView, coordinator: ARMeshCoordinator) {
        uiView.session.pause()
    }
}

final class ARMeshCoordinator: NSObject, ARSessionDelegate, NSCoding {
    let onCoverageUpdate: (Int, Int) -> Void

    private(set) var capturedFrames: [CapturedFrame] = []

    let sessionRoot: URL
    let framesRoot: URL

    private var lastSnapshotTransform: simd_float4x4?
    private var lastSnapshotTimestamp: TimeInterval = -1
    private let saveQueue = DispatchQueue(label: "com.vista.tsdf-frame-save",
                                          qos: .userInitiated)
    private var snapshotsInFlight = 0
    private var snapshotIndex = 0

    private let minSnapshotInterval: TimeInterval = 1.0 / 15.0
    private let translationThresholdMeters: Float = 0.05
    private let rotationThresholdRadians: Float = 0.052

    private var lastMeshCount = 0

    // MARK: coverage overlay state (one-shot wavefront, wireframe mesh)
    private weak var overlayView: ARView?
    private var overlayRoot: AnchorEntity?
    private var meshEntities: [UUID: ModelEntity] = [:]
    private var edgeEntities: [UUID: ModelEntity] = [:]   // v6 orange crease ribbons
    private var lastMeshRebuild: [UUID: TimeInterval] = [:]
    private var lastTouched: [UUID: TimeInterval] = [:]
    private var lastVertexCount: [UUID: Int] = [:]
    private var lastGlowTick: TimeInterval = 0
    private var lastReconcile: TimeInterval = 0           // v6.2 self-heal cadence
    private let meshRebuildInterval: TimeInterval = 2.5   // v6.1: was 0.8 — 44-chunk churn lagged the camera
    private let glowDuration: TimeInterval = 1.2

    init(onCoverageUpdate: @escaping (Int, Int) -> Void) {
        self.onCoverageUpdate = onCoverageUpdate
        let stamp = Int(Date().timeIntervalSince1970)
        self.sessionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vista_room_\(stamp)", isDirectory: true)
        self.framesRoot = sessionRoot.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: framesRoot,
                                                 withIntermediateDirectories: true)
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("ARMeshCoordinator is not designed to be decoded")
    }
    func encode(with coder: NSCoder) { }

    // MARK: - Coverage overlay (v5: one-shot ORANGE flash -> settled TEAL Vista mesh)

    func attachOverlay(to view: ARView) {
        overlayView = view
        let root = AnchorEntity(world: matrix_identity_float4x4)
        view.scene.addAnchor(root)
        overlayRoot = root
    }

    /// v4 wireframe edge-lines texture, built once. White triangle-edge
    /// lines on a fully transparent background, in barycentric UV space
    /// (every triangle maps to the SAME (0,0)/(1,0)/(0,1) UVs, so these
    /// lines render as the mesh's actual wireframe). White in BOTH color
    /// and alpha so it reads correctly whichever channel the opacity
    /// parameter samples. Mipmapped: lines naturally thin with distance.
    private static let wireTexture: TextureResource? = {
        let S = 256
        guard let ctx = CGContext(data: nil, width: S, height: S,
                                  bitsPerComponent: 8, bytesPerRow: S * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))
        // v5: faint glow FILL across the whole triangle (16%) — captured
        // surfaces read as translucent hologram glass, lines render on top.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
        ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(CGFloat(S) * 0.10)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: S, y: 0))
        ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: S))
        ctx.move(to: CGPoint(x: S, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: S))
        ctx.strokePath()
        guard let img = ctx.makeImage() else { return nil }
        return try? TextureResource.generate(
            from: img,
            options: .init(semantic: .color,
                           mipmapsMode: .allocateAndGenerateAll))
    }()

    /// v6: persistent hot-orange accent for crease ribbons — the Vista
    /// brand's second color, always on once a corner is captured.
    private static let edgeMaterial: UnlitMaterial = {
        var m = UnlitMaterial()
        m.color = .init(tint: UIColor(red: 1.00, green: 0.50, blue: 0.10,
                                      alpha: 1.0))
        m.blending = .transparent(opacity: .init(floatLiteral: 0.95))
        return m
    }()

    /// v6: build thin orange ribbons along GEOMETRIC CREASES of a chunk —
    /// edges whose two adjacent faces bend hard (dot < 0.5 ~ >60 deg):
    /// wall-wall and wall-floor corners, furniture silhouettes. Boundary
    /// edges (1 adjacent face) are chunk tiling seams mid-surface — skipped,
    /// or every chunk would draw a fake orange rectangle. Ribbons are lifted
    /// 3mm along the average normal and emitted with BOTH windings so they
    /// render from every side without needing face-culling control.
    private static func creaseMesh(from geo: ARMeshGeometry) -> MeshResource? {
        let vCount = geo.vertices.count
        let fCount = geo.faces.count
        guard vCount > 0, fCount > 0 else { return nil }
        var P = [SIMD3<Float>]()
        P.reserveCapacity(vCount)
        let vBase = geo.vertices.buffer.contents().advanced(by: geo.vertices.offset)
        let vStride = geo.vertices.stride
        for i in 0..<vCount {
            let f = vBase.advanced(by: i * vStride).assumingMemoryBound(to: Float.self)
            P.append(SIMD3<Float>(f[0], f[1], f[2]))
        }
        let bytesPerIndex = geo.faces.bytesPerIndex
        let iBase = geo.faces.buffer.contents()
        func vid(_ t: Int) -> Int {
            bytesPerIndex == 4
                ? Int(iBase.advanced(by: t * 4).assumingMemoryBound(to: UInt32.self).pointee)
                : Int(iBase.advanced(by: t * 2).assumingMemoryBound(to: UInt16.self).pointee)
        }
        struct EdgeInfo { var n0 = SIMD3<Float>.zero; var n1 = SIMD3<Float>.zero; var count = 0 }
        var edges = [UInt64: EdgeInfo](minimumCapacity: fCount * 3)
        for f in 0..<fCount {
            let a = vid(f * 3), b = vid(f * 3 + 1), c = vid(f * 3 + 2)
            let n = simd_cross(P[b] - P[a], P[c] - P[a])
            let l = simd_length(n)
            if l < 1e-10 { continue }
            let nn = n / l
            for (i, j) in [(a, b), (b, c), (c, a)] {
                let key = (UInt64(min(i, j)) << 32) | UInt64(max(i, j))
                var e = edges[key] ?? EdgeInfo()
                if e.count == 0 { e.n0 = nn } else if e.count == 1 { e.n1 = nn }
                e.count += 1
                edges[key] = e
            }
        }
        var pos = [SIMD3<Float>]()
        var tris = [UInt32]()
        let halfW: Float = 0.006   // 6mm half-width ribbon
        let lift: Float = 0.003    // 3mm off the surface (no z-fight)
        let minLen: Float = 0.03   // skip sub-3cm noise edges
        // v6.1: dot < 0.25 (~>75 deg) — 60 deg tripped on couch folds and
        // clutter and painted orange everywhere. Real wall/floor corners
        // are ~90 deg (dot ~0); only those + hard furniture edges survive.
        for (key, e) in edges {
            guard e.count == 2, simd_dot(e.n0, e.n1) < 0.25 else { continue }
            let p0 = P[Int(key >> 32)]
            let p1 = P[Int(key & 0xFFFFFFFF)]
            let d = p1 - p0
            let len = simd_length(d)
            if len < minLen { continue }
            var n = e.n0 + e.n1
            let nl = simd_length(n)
            n = nl > 1e-6 ? n / nl : e.n0
            let w = simd_normalize(simd_cross(d / len, n)) * halfW
            let o = n * lift
            let base = UInt32(pos.count)
            pos.append(p0 - w + o); pos.append(p0 + w + o)
            pos.append(p1 - w + o); pos.append(p1 + w + o)
            tris += [base, base + 1, base + 2,  base + 1, base + 3, base + 2,
                     base + 2, base + 1, base,  base + 2, base + 3, base + 1]
        }
        guard !pos.isEmpty else { return nil }
        var desc = MeshDescriptor()
        desc.positions = MeshBuffer(pos)
        desc.primitives = .triangles(tris)
        return try? MeshResource.generate(from: [desc])
    }

    /// v5 VISTA SIGNATURE palette (Steve's brand video): progress 0 = just
    /// scanned, HOT ORANGE; 1 = settled, glowing TEAL mesh. Lines render at
    /// full strength over a faint 16% glow fill (baked into the texture), so
    /// covered surfaces read as translucent hologram glass with a bright
    /// wire grid. Untouched surfaces show nothing = unscanned.
    private static func overlayMaterial(progress: Float) -> UnlitMaterial {
        let t = max(0, min(1, progress))
        // orange (1.00, 0.45, 0.05) -> teal (0.05, 0.95, 0.80)
        let r = 1.00 + (0.05 - 1.00) * t
        let g = 0.45 + (0.95 - 0.45) * t
        let b = 0.05 + (0.80 - 0.05) * t
        var m = UnlitMaterial()
        let tint = UIColor(red: CGFloat(r), green: CGFloat(g),
                           blue: CGFloat(b), alpha: 1.0)
        if let tex = wireTexture {
            let opacity = 1.00 + (0.85 - 1.00) * t
            m.color = .init(tint: tint, texture: .init(tex))
            m.blending = .transparent(
                opacity: .init(scale: opacity, texture: .init(tex)))
        } else {
            // Fallback: solid veil (35% fresh -> 20% settled).
            let opacity = 0.35 + (0.20 - 0.35) * t
            m.color = .init(tint: tint)
            m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        }
        return m
    }

    /// Safe 3-float vertex reads (packed 12-byte stride; SIMD3<Float> pointee
    /// would over-read 16 bytes on the final vertex).
    private static func overlayMesh(from geo: ARMeshGeometry) -> MeshResource? {
        let vCount = geo.vertices.count
        guard vCount > 0, geo.faces.count > 0 else { return nil }
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(vCount)
        let vBase = geo.vertices.buffer.contents().advanced(by: geo.vertices.offset)
        let stride = geo.vertices.stride
        for i in 0..<vCount {
            let f = vBase.advanced(by: i * stride).assumingMemoryBound(to: Float.self)
            positions.append(SIMD3<Float>(f[0], f[1], f[2]))
        }
        let idxCount = geo.faces.count * 3
        var indices = [UInt32]()
        indices.reserveCapacity(idxCount)
        let bytesPerIndex = geo.faces.bytesPerIndex
        let iBase = geo.faces.buffer.contents()
        for t in 0..<idxCount {
            if bytesPerIndex == 4 {
                indices.append(iBase.advanced(by: t * 4)
                    .assumingMemoryBound(to: UInt32.self).pointee)
            } else {
                indices.append(UInt32(iBase.advanced(by: t * 2)
                    .assumingMemoryBound(to: UInt16.self).pointee))
            }
        }
        // v4 wireframe: duplicate vertices PER TRIANGLE so each face carries
        // the same barycentric UVs (0,0)/(1,0)/(0,1) into the edge-lines
        // texture. 3 verts/face (~3x v3's shared verts) — fine at chunk scale.
        let faceCount = idxCount / 3
        var wirePos = [SIMD3<Float>]()
        var wireUV = [SIMD2<Float>]()
        var wireIdx = [UInt32]()
        wirePos.reserveCapacity(idxCount)
        wireUV.reserveCapacity(idxCount)
        wireIdx.reserveCapacity(idxCount)
        let triUV: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)]
        for f in 0..<faceCount {
            for k in 0..<3 {
                wirePos.append(positions[Int(indices[f * 3 + k])])
                wireUV.append(triUV[k])
                wireIdx.append(UInt32(f * 3 + k))
            }
        }
        var desc = MeshDescriptor()
        desc.positions = MeshBuffer(wirePos)
        desc.textureCoordinates = MeshBuffer(wireUV)
        desc.primitives = .triangles(wireIdx)
        return try? MeshResource.generate(from: [desc])
    }

    private func upsertOverlay(for anchor: ARMeshAnchor, force: Bool,
                               flash: Bool = true) {
        guard let root = overlayRoot else { return }
        let now = Date().timeIntervalSince1970
        let existing = meshEntities[anchor.identifier]

        // Transform refresh is cheap — do it every time.
        existing?.transform = Transform(matrix: anchor.transform)
        edgeEntities[anchor.identifier]?.transform = Transform(matrix: anchor.transform)

        // Mesh rebuild is throttled per anchor.
        if !force, let last = lastMeshRebuild[anchor.identifier],
           now - last < meshRebuildInterval {
            return
        }
        let vCount = anchor.geometry.vertices.count

        // One-shot wavefront: a chunk is 'fresh' only on first appearance or
        // when it genuinely GROWS (new geometry = newly scanned area).
        // Refinement updates swap the mesh silently — no re-flash, no strobe.
        let prevV = lastVertexCount[anchor.identifier] ?? 0
        let grown = vCount > Int(Double(prevV) * 1.15) + 50

        // v6.1 perf: if this chunk already has an entity and its geometry
        // hasn't changed size, skip the rebuild entirely. ARKit refines
        // anchors continuously; rebuilding 40+ wireframe meshes + crease
        // maps that hadn't visibly changed was the 400-frame camera lag.
        if existing != nil, !grown, vCount == prevV {
            lastMeshRebuild[anchor.identifier] = now
            return
        }

        guard let mesh = Self.overlayMesh(from: anchor.geometry) else { return }
        lastMeshRebuild[anchor.identifier] = now
        lastVertexCount[anchor.identifier] = max(prevV, vCount)

        if let entity = existing {
            entity.model?.mesh = mesh
            if grown {
                lastTouched[anchor.identifier] = now
                entity.model?.materials = [Self.overlayMaterial(progress: 0)]
            }
        } else {
            // v6.2: healed chunks (flash=false) appear already settled —
            // a relocalization restore must not fake an orange wavefront.
            if flash { lastTouched[anchor.identifier] = now }
            let entity = ModelEntity(
                mesh: mesh,
                materials: [Self.overlayMaterial(progress: flash ? 0 : 1)])
            entity.transform = Transform(matrix: anchor.transform)
            root.addChild(entity)
            meshEntities[anchor.identifier] = entity
        }

        // v6: rebuild the orange crease ribbons on the same throttle.
        if let cmesh = Self.creaseMesh(from: anchor.geometry) {
            if let ee = edgeEntities[anchor.identifier] {
                ee.model?.mesh = cmesh
                ee.transform = Transform(matrix: anchor.transform)
            } else {
                let ee = ModelEntity(mesh: cmesh, materials: [Self.edgeMaterial])
                ee.transform = Transform(matrix: anchor.transform)
                root.addChild(ee)
                edgeEntities[anchor.identifier] = ee
            }
        } else if let ee = edgeEntities.removeValue(forKey: anchor.identifier) {
            ee.removeFromParent()   // refinement smoothed the creases away
        }
    }

    /// 10Hz: cool freshly scanned chunks from cyan to the settled veil.
    /// Only entities inside the glow window get material swaps, so the
    /// steady-state cost is zero.
    private func glowTick() {
        let now = Date().timeIntervalSince1970
        guard now - lastGlowTick > 0.1 else { return }
        lastGlowTick = now
        for (id, entity) in meshEntities {
            guard let touched = lastTouched[id] else { continue }
            let age = now - touched
            guard age < glowDuration + 0.3 else { continue }
            let t = Float(min(max(age / glowDuration, 0), 1))
            entity.model?.materials = [Self.overlayMaterial(progress: t)]
        }
    }

    private func removeOverlay(for anchor: ARMeshAnchor) {
        if let entity = meshEntities.removeValue(forKey: anchor.identifier) {
            entity.removeFromParent()
        }
        if let ee = edgeEntities.removeValue(forKey: anchor.identifier) {
            ee.removeFromParent()
        }
        lastMeshRebuild.removeValue(forKey: anchor.identifier)
        lastTouched.removeValue(forKey: anchor.identifier)
        lastVertexCount.removeValue(forKey: anchor.identifier)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors {
            upsertOverlay(for: mesh, force: true)
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors {
            upsertOverlay(for: mesh, force: false)
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors {
            removeOverlay(for: mesh)
        }
    }

    // MARK: - Frame capture

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        glowTick()

        // v6.2 self-heal: after a tracking reset/relocalization, restored
        // anchors are not reliably re-announced via didAdd — rebuild any
        // live anchor missing its overlay (max 8/tick so a 30-chunk restore
        // doesn't hitch the camera), and drop overlays whose anchors died.
        let nowR = Date().timeIntervalSince1970
        if nowR - lastReconcile > 1.0 {
            lastReconcile = nowR
            let liveMesh = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            var liveIDs = Set<UUID>(minimumCapacity: liveMesh.count)
            var healed = 0
            for m in liveMesh {
                liveIDs.insert(m.identifier)
                if meshEntities[m.identifier] == nil, healed < 8 {
                    healed += 1
                    upsertOverlay(for: m, force: true, flash: false)
                }
            }
            for id in Array(meshEntities.keys) where !liveIDs.contains(id) {
                if let e = meshEntities.removeValue(forKey: id) { e.removeFromParent() }
                if let ee = edgeEntities.removeValue(forKey: id) { ee.removeFromParent() }
                lastMeshRebuild.removeValue(forKey: id)
                lastTouched.removeValue(forKey: id)
                lastVertexCount.removeValue(forKey: id)
            }
        }

        let meshCount = frame.anchors.compactMap { $0 as? ARMeshAnchor }.count
        let needsCoverageUpdate = (meshCount != lastMeshCount)
        if needsCoverageUpdate { lastMeshCount = meshCount }

        let camTransform = frame.camera.transform
        let timeOK = (frame.timestamp - lastSnapshotTimestamp) >= minSnapshotInterval
        let motionOK: Bool = {
            guard let last = lastSnapshotTransform else { return true }
            let posDelta = positionalDelta(camTransform, last)
            let rotDelta = rotationalDelta(camTransform, last)
            return posDelta >= translationThresholdMeters
                || rotDelta >= rotationThresholdRadians
        }()
        let inFlightOK = snapshotsInFlight < 6

        if timeOK && motionOK && inFlightOK {
            guard let snap = FrameSnapshotter.snapshot(from: frame) else {
                if needsCoverageUpdate {
                    DispatchQueue.main.async {
                        self.onCoverageUpdate(meshCount, self.capturedFrames.count)
                    }
                }
                return
            }
            lastSnapshotTransform = camTransform
            lastSnapshotTimestamp = frame.timestamp
            snapshotsInFlight += 1
            let idx = snapshotIndex
            snapshotIndex += 1

            saveQueue.async { [weak self] in
                guard let self else { return }
                defer {
                    DispatchQueue.main.async { self.snapshotsInFlight -= 1 }
                }
                do {
                    let folder = try FrameDiskWriter.write(snap,
                                                           index: idx,
                                                           framesRoot: self.framesRoot)
                    let cf = CapturedFrame(
                        id: UUID(),
                        transform: snap.cameraTransform,
                        intrinsics: snap.intrinsics,
                        imageWidth: snap.imageWidth,
                        imageHeight: snap.imageHeight,
                        imageURL: folder.appendingPathComponent("rgb.jpg")
                    )
                    DispatchQueue.main.async {
                        self.capturedFrames.append(cf)
                        self.onCoverageUpdate(meshCount, self.capturedFrames.count)
                    }
                } catch {
                    // silent
                }
            }
        } else if needsCoverageUpdate {
            DispatchQueue.main.async {
                self.onCoverageUpdate(meshCount, self.capturedFrames.count)
            }
        }
    }

    private func positionalDelta(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let pa = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        return simd_distance(pa, pb)
    }
    private func rotationalDelta(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let qa = simd_quatf(a)
        let qb = simd_quatf(b)
        let dot = abs(simd_dot(qa, qb))
        let clamped = min(max(dot, -1), 1)
        return 2 * acos(clamped)
    }
}

enum ARMeshExportError: LocalizedError {
    case noCurrentFrame
    case noMeshAnchors
    case noCoordinator
    case usdzWriteFailed

    var errorDescription: String? {
        switch self {
        case .noCurrentFrame: return "AR session has no current frame"
        case .noMeshAnchors:  return "No mesh data captured — scan more of the room before tapping Done"
        case .noCoordinator:  return "Lost reference to capture coordinator"
        case .usdzWriteFailed: return "SceneKit USDZ write returned false"
        }
    }
}

enum ARMeshExporter {
    private static let textureMaxDimension: CGFloat = 768
    private static let edgeMarginThreshold: Float = 0.04
    private static let maxTextureFrames = 60

    @MainActor
    static func export(arView: ARView) async throws -> URL {
        guard let frame = arView.session.currentFrame else {
            throw ARMeshExportError.noCurrentFrame
        }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { throw ARMeshExportError.noMeshAnchors }
        guard let coord = arView.session.delegate as? ARMeshCoordinator else {
            throw ARMeshExportError.noCoordinator
        }
        let allFrames = coord.capturedFrames
        let framesRoot = coord.framesRoot
        let sessionRoot = coord.sessionRoot

        let texFrames = subsampleFrames(allFrames, maxCount: maxTextureFrames)

        arView.session.pause()

        return try await Task.detached(priority: .userInitiated) {
            let primaryURL = sessionRoot.appendingPathComponent("room.usdz")
            let phase1URL = sessionRoot.appendingPathComponent("room_phase1.usdz")

            // 1. Always build Phase 1 USDZ at room_phase1.usdz as the fallback.
            try buildUSDZ(from: meshAnchors, frames: texFrames, to: phase1URL)

            // 2. ARMeshAnchor combined mesh as binary PLY (Phase 5 bake input).
            //    Always written -- this is the geometry source the cloud bake
            //    consumes. Failures here non-fatal; bundle export below skips
            //    if mesh isn't present.
            let armeshURL = sessionRoot.appendingPathComponent("armesh.ply")
            do {
                try MeshPLYExporter.exportArMeshAnchors(meshAnchors, to: armeshURL)
            } catch {
                // ignore — bundle export below will detect missing mesh
            }

            // 3. Naive cloud PLY (Phase 1 sanity baseline — debug artifact).
            do {
                let plyURL = sessionRoot.appendingPathComponent("naive_cloud.ply")
                _ = try NaiveCloudExporter.export(framesRoot: framesRoot, to: plyURL)
            } catch {
                // ignore — debug-only
            }

            // 4. TSDF: compute mesh, write PLY + USDZ.
            var tsdfPrimaryUsed = false
            do {
                let mesh = try TSDFPipeline.computeMesh(framesRoot: framesRoot)
                if !mesh.triangles.isEmpty {
                    let tsdfPLY = sessionRoot.appendingPathComponent("tsdf_mesh.ply")
                    try PLYBinaryExporter.writeMesh(
                        positions: mesh.positions,
                        colors: mesh.colors,
                        triangles: mesh.triangles,
                        to: tsdfPLY
                    )
                    try TSDFPipeline.buildUSDZ(mesh: mesh, to: primaryURL)
                    tsdfPrimaryUsed = true
                }
            } catch {
                // ignore — fall back to Phase 1 USDZ below
            }

            if !tsdfPrimaryUsed {
                try? FileManager.default.copyItem(at: phase1URL, to: primaryURL)
            }

            // 5. Phase 5.0 bake bundle. Self-contained payload in Documents/
            //    so iMazing / Apple Devices can pull it off the device.
            //    Failures here do NOT block the Library USDZ.
            do {
                let scanName = sessionRoot.lastPathComponent  // e.g. "vista_room_<ts>"
                // A5: prefer the TSDF-fused mesh as the bundle's mesh.ply (cloud-bake input).
                // Falls back to ARMeshAnchor mesh only if TSDF didn't produce triangles.
                let bundleMeshURL: URL = tsdfPrimaryUsed
                    ? sessionRoot.appendingPathComponent("tsdf_mesh.ply")
                    : armeshURL
                _ = try BundleExporter.exportBundle(
                    scanName: scanName,
                    meshURL: bundleMeshURL,
                    framesRoot: framesRoot
                )
            } catch {
                // ignore — bundle is dev-only for Phase 5.0
            }

            return primaryURL
        }.value
    }

    private static func subsampleFrames(_ frames: [CapturedFrame],
                                        maxCount: Int) -> [CapturedFrame] {
        if frames.count <= maxCount { return frames }
        var picked: [CapturedFrame] = []
        picked.reserveCapacity(maxCount)
        let step = Double(frames.count) / Double(maxCount)
        for i in 0..<maxCount {
            let idx = min(frames.count - 1, Int(Double(i) * step))
            picked.append(frames[idx])
        }
        return picked
    }

    private struct FrameGroup {
        var positions: [SCNVector3] = []
        var uvs: [CGPoint] = []
    }

    private static func buildUSDZ(from anchors: [ARMeshAnchor],
                                  frames: [CapturedFrame],
                                  to outURL: URL) throws {
        let scene = SCNScene()
        var groups: [UUID: FrameGroup] = [:]
        var fallback = FrameGroup()

        for anchor in anchors {
            processAnchor(anchor, frames: frames,
                          groups: &groups, fallback: &fallback)
        }

        for (fid, group) in groups {
            autoreleasepool {
                guard let frame = frames.first(where: { $0.id == fid }) else {
                    let node = makeNode(group: group, texture: nil)
                    scene.rootNode.addChildNode(node)
                    return
                }
                guard let img = UIImage(contentsOfFile: frame.imageURL.path) else {
                    let node = makeNode(group: group, texture: nil)
                    scene.rootNode.addChildNode(node)
                    return
                }
                let scaled = downscaleImage(img, maxDimension: textureMaxDimension)
                let node = makeNode(group: group, texture: scaled)
                scene.rootNode.addChildNode(node)
            }
        }
        if !fallback.positions.isEmpty {
            let node = makeNode(group: fallback, texture: nil)
            scene.rootNode.addChildNode(node)
        }

        let ok = scene.write(to: outURL, options: nil, delegate: nil, progressHandler: nil)
        guard ok else { throw ARMeshExportError.usdzWriteFailed }
    }

    private static func downscaleImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        if longest <= maxDimension { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: floor(size.width * scale),
                             height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func processAnchor(_ anchor: ARMeshAnchor,
                                      frames: [CapturedFrame],
                                      groups: inout [UUID: FrameGroup],
                                      fallback: inout FrameGroup) {
        let geo = anchor.geometry
        let transform = anchor.transform
        let vCount = geo.vertices.count

        var worldVerts = [SIMD3<Float>](repeating: .zero, count: vCount)
        let vBase = geo.vertices.buffer.contents()
        let vOffset = geo.vertices.offset
        let vStride = geo.vertices.stride

        for i in 0..<vCount {
            let local = vBase.advanced(by: vOffset + i * vStride)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let worldH = transform * SIMD4<Float>(local, 1)
            worldVerts[i] = SIMD3<Float>(worldH.x, worldH.y, worldH.z)
        }

        let triCount = geo.faces.count
        let bytesPerIndex = geo.faces.bytesPerIndex
        let primCount = geo.faces.indexCountPerPrimitive
        precondition(primCount == 3, "Expected triangles")
        let idxBase = geo.faces.buffer.contents()

        for t in 0..<triCount {
            let a = readIndex(at: idxBase, tri: t, idx: 0, bytesPerIndex: bytesPerIndex)
            let b = readIndex(at: idxBase, tri: t, idx: 1, bytesPerIndex: bytesPerIndex)
            let c = readIndex(at: idxBase, tri: t, idx: 2, bytesPerIndex: bytesPerIndex)

            let pA = worldVerts[a]
            let pB = worldVerts[b]
            let pC = worldVerts[c]

            let centroid = (pA + pB + pC) / 3.0
            let edge1 = pB - pA
            let edge2 = pC - pA
            let normalRaw = simd_cross(edge1, edge2)
            let lenSq = simd_length_squared(normalRaw)
            if lenSq < 1e-10 { continue }
            let normal = normalRaw / sqrt(lenSq)

            if let bf = pickBestFrameForTriangle(centroid: centroid,
                                                 normal: normal,
                                                 frames: frames) {
                let uvA = projectClamped(pA, frame: bf)
                let uvB = projectClamped(pB, frame: bf)
                let uvC = projectClamped(pC, frame: bf)
                if groups[bf.id] == nil { groups[bf.id] = FrameGroup() }
                groups[bf.id]!.positions.append(SCNVector3(pA.x, pA.y, pA.z))
                groups[bf.id]!.positions.append(SCNVector3(pB.x, pB.y, pB.z))
                groups[bf.id]!.positions.append(SCNVector3(pC.x, pC.y, pC.z))
                groups[bf.id]!.uvs.append(CGPoint(x: CGFloat(uvA.0), y: CGFloat(uvA.1)))
                groups[bf.id]!.uvs.append(CGPoint(x: CGFloat(uvB.0), y: CGFloat(uvB.1)))
                groups[bf.id]!.uvs.append(CGPoint(x: CGFloat(uvC.0), y: CGFloat(uvC.1)))
            } else {
                fallback.positions.append(SCNVector3(pA.x, pA.y, pA.z))
                fallback.positions.append(SCNVector3(pB.x, pB.y, pB.z))
                fallback.positions.append(SCNVector3(pC.x, pC.y, pC.z))
                fallback.uvs.append(.zero); fallback.uvs.append(.zero); fallback.uvs.append(.zero)
            }
        }
    }

    private static func readIndex(at base: UnsafeRawPointer,
                                  tri: Int, idx: Int,
                                  bytesPerIndex: Int) -> Int {
        let offset = (tri * 3 + idx) * bytesPerIndex
        if bytesPerIndex == 4 {
            return Int(base.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee)
        } else {
            return Int(base.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee)
        }
    }

    private static func pickBestFrameForTriangle(centroid: SIMD3<Float>,
                                                 normal: SIMD3<Float>,
                                                 frames: [CapturedFrame]) -> CapturedFrame? {
        if frames.isEmpty { return nil }
        var bestScore: Float = -Float.greatestFiniteMagnitude
        var best: CapturedFrame?

        for f in frames {
            let cameraPos = SIMD3<Float>(f.transform.columns.3.x,
                                         f.transform.columns.3.y,
                                         f.transform.columns.3.z)
            let toCamera = simd_normalize(cameraPos - centroid)
            let alignment = simd_dot(normal, toCamera)
            if alignment < 0.15 { continue }
            let dist = simd_distance(cameraPos, centroid)
            if dist < 0.15 || dist > 7.0 { continue }
            guard let uv = projectToImageUV(centroid, frame: f) else { continue }
            let edgeMargin = min(uv.0, 1 - uv.0, uv.1, 1 - uv.1)
            if edgeMargin < edgeMarginThreshold { continue }
            let alignBoost = alignment * alignment
            let edgeBoost = min((edgeMargin - edgeMarginThreshold) / 0.08, 1.0)
            let score = alignBoost * (0.7 + 0.3 * edgeBoost) / max(dist, 0.3)
            if score > bestScore { bestScore = score; best = f }
        }
        return best
    }

    private static func projectToImageUV(_ worldPos: SIMD3<Float>,
                                         frame: CapturedFrame) -> (Float, Float)? {
        let inv = simd_inverse(frame.transform)
        let camH = inv * SIMD4<Float>(worldPos, 1)
        let cam = SIMD3<Float>(camH.x, camH.y, camH.z)
        if cam.z >= 0 { return nil }
        let depth = -cam.z
        let xN = cam.x / depth
        let yN = cam.y / depth
        let pixel = frame.intrinsics * SIMD3<Float>(xN, yN, 1)
        let u = pixel.x, v = pixel.y
        if u < 0 || u >= Float(frame.imageWidth) { return nil }
        if v < 0 || v >= Float(frame.imageHeight) { return nil }
        return (u / Float(frame.imageWidth), 1.0 - v / Float(frame.imageHeight))
    }

    private static func projectClamped(_ worldPos: SIMD3<Float>,
                                       frame: CapturedFrame) -> (Float, Float) {
        let inv = simd_inverse(frame.transform)
        let camH = inv * SIMD4<Float>(worldPos, 1)
        let cam = SIMD3<Float>(camH.x, camH.y, camH.z)
        if cam.z >= -0.001 { return (0.5, 0.5) }
        let depth = -cam.z
        let xN = cam.x / depth
        let yN = cam.y / depth
        let pixel = frame.intrinsics * SIMD3<Float>(xN, yN, 1)
        if pixel.x.isNaN || pixel.y.isNaN { return (0.5, 0.5) }
        let uClamped = min(max(pixel.x, 0), Float(frame.imageWidth) - 1)
        let vClamped = min(max(pixel.y, 0), Float(frame.imageHeight) - 1)
        return (uClamped / Float(frame.imageWidth),
                1.0 - vClamped / Float(frame.imageHeight))
    }

    private static func makeNode(group: FrameGroup, texture: UIImage?) -> SCNNode {
        let posSource = SCNGeometrySource(vertices: group.positions)
        let uvSource = SCNGeometrySource(textureCoordinates: group.uvs)
        let triCount = group.positions.count / 3
        var indices = [UInt32]()
        indices.reserveCapacity(triCount * 3)
        for i in 0..<(triCount * 3) { indices.append(UInt32(i)) }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: triCount,
            bytesPerIndex: 4
        )
        let geom = SCNGeometry(sources: [posSource, uvSource], elements: [element])
        let mat = SCNMaterial()
        mat.isDoubleSided = true
        mat.lightingModel = .physicallyBased
        if let img = texture {
            mat.diffuse.contents = img
            mat.diffuse.wrapS = .clamp
            mat.diffuse.wrapT = .clamp
        } else {
            mat.diffuse.contents = UIColor(white: 0.78, alpha: 1.0)
        }
        geom.materials = [mat]
        return SCNNode(geometry: geom)
    }
}

#Preview {
    RoomCaptureView()
}
