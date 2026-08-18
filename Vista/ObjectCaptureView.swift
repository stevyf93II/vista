//
//  ObjectCaptureView.swift
//  Vista
//
//  Object Capture v2 (2026-06-10) — depth + gravity + masks photogrammetry.
//
//  WHAT CHANGED vs v1:
//  - The green bounding box is GONE. It was never wired into the pipeline —
//    PhotogrammetrySession only ever received the photo folder — so the box,
//    its gestures, and ~400 lines of placement code were pure ceremony.
//    Capture is now: aim, Start, orbit.
//  - Reconstruction input upgraded from a bare JPEG folder to the iOS 17+
//    sequence-of-samples API. Each PhotogrammetrySample carries:
//      depthDataMap  — LiDAR depth at capture time (real-world scale,
//                      geometry assist)
//      gravity       — upright orientation
//      objectMask    — Vision foreground-instance mask = AUTOMATIC object
//                      isolation; the background never enters the model.
//    (depthConfidenceMap is get-only on iOS; confidence sidecars are still
//    saved at capture time for future cloud-side use.)
//    Samples are built LAZILY, one at a time, so 12 MP buffers never pile up
//    in memory. Every enrichment is optional per frame — a sample degrades
//    gracefully to image-only (v1 behavior) if depth/mask/gravity is missing.
//  - Detail: iOS exposes only .preview/.reduced; we use .reduced. The
//    fallback chain stays in place for when Apple opens up .medium.
//
//  Day 9.5 — ARSession.captureHighResolutionFrame for source images (kept).
//
//  Tier 1 detail pass (2026-06-10): more sharp pixels into .reduced —
//  [T1-1] photo budget 60 -> 120 target / 150 -> 250 max, cadence tightened
//         (~6 deg / 9 cm) + a FOURTH close-up orbit in the guidance
//         (pixels-on-target is what becomes texture detail);
//  [T1-2] recommendedVideoFormatForHighResolutionFrameCapturing is now set —
//         without it captureHighResolutionFrame can serve plain video res
//         on some devices (12 MP is ARKit's ceiling; 48 MP isn't reachable
//         inside an ARKit session);
//  [T1-3] blur gate: per-photo Laplacian sharpness on a 256px thumb,
//         self-calibrating threshold (30% of running best) — motion-blurred
//         frames are rejected and recaptured instead of fed to the model.
//

import SwiftUI
import ARKit
import RealityKit
import CoreMotion
import Vision
import simd
import UIKit
import CoreImage

struct ObjectCaptureView: View {
    @AppStorage("renderBaseURL") private var renderBaseURL: String = ""
    @AppStorage("uploadToken") private var uploadToken: String = ""
    @AppStorage("slugPrefix") private var slugPrefix: String = "vista-"

    @State private var phase: Phase = .idle
    @State private var showCaptureSheet = false

    enum Phase {
        case idle
        case processing(Float, String)
        case ready(URL)
        case uploading
        case uploaded(UploadResult)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 20)
                    Image(systemName: "cube.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.tint)
                    Text("Object Capture")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text("Aim at the object and tap Start. Orbit slowly at three heights — low, level, high — then a close-up pass filling the frame. Blurry shots are rejected automatically. 12 MP photos plus LiDAR depth and an automatic object mask feed on-device photogrammetry (~5–10 min). No box to place; isolation is automatic.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Divider().padding(.horizontal, 40)
                    if !isLidarSupported {
                        unsupportedNotice
                    } else {
                        actionArea
                    }
                    Spacer()
                }
            }
            .navigationTitle("Object")
        }
        .fullScreenCover(isPresented: $showCaptureSheet) {
            ObjectCaptureSheet(
                onFinish: { framesFolder in
                    showCaptureSheet = false
                    Task { await runPhotogrammetry(framesFolder: framesFolder) }
                },
                onCancel: { showCaptureSheet = false },
                onError: handleScanError
            )
        }
    }

    private var isLidarSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    private var unsupportedNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title2)
            Text("Requires iPhone 12 Pro or later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var actionArea: some View {
        switch phase {
        case .idle:
            Button { showCaptureSheet = true } label: {
                Label("Start Object Scan", systemImage: "viewfinder.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if uploadToken.isEmpty {
                Text("Tip: set Upload Token in Settings to enable optional sharing.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        case .processing(let pct, let stage):
            VStack(spacing: 12) {
                ProgressView(value: pct)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)
                Text("\(stage) — \(Int(pct * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Photogrammetry with depth + object masks: ~5–10 minutes. Keep the app open.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        case .ready(let url):
            VStack(spacing: 12) {
                Label("Saved to Library", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(url.lastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int {
                    Text(byteSizeString(size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Open the Library tab to view in 3D / AR.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button { Task { await upload(url) } } label: {
                    Label("Share via Vista cloud", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploadToken.isEmpty)
                if uploadToken.isEmpty {
                    Text("Set Upload Token in Settings to share")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Button("Done") { phase = .idle }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
        case .uploading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Uploading...").font(.caption).foregroundStyle(.secondary)
            }
        case .uploaded(let result):
            VStack(alignment: .leading, spacing: 6) {
                Label("Shared", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
                Text(result.filename).font(.caption2).foregroundStyle(.secondary)
                Text(result.url).font(.caption2.monospaced()).foregroundStyle(.tint).textSelection(.enabled)
                Button("Scan another object") { phase = .idle }.font(.caption).padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding().background(Color(.secondarySystemBackground)).cornerRadius(10).padding(.horizontal, 24)
        case .failed(let msg):
            VStack(spacing: 8) {
                Label("Failed", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                Text(msg).font(.caption2.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { phase = .idle }.font(.caption)
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

    private func handleScanError(_ error: Error) {
        showCaptureSheet = false
        phase = .failed(error.localizedDescription)
    }

    // MARK: - Photogrammetry (samples input: depth + gravity + masks)

    /// Runs photogrammetry over a LAZY sequence of enriched samples. iOS
    /// exposes only .preview/.reduced detail; the chain structure remains so
    /// higher levels can be added the day Apple enables them on iOS.
    private func runPhotogrammetry(framesFolder: URL) async {
        phase = .processing(0, "Preparing samples")
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        let detailsToTry: [PhotogrammetrySession.Request.Detail] = [.reduced]
        var lastError = "Photogrammetry failed"

        for detail in detailsToTry {
            do {
                let done = try await runPhotogrammetryOnce(framesFolder: framesFolder,
                                                           detail: detail)
                if done {
                    try? FileManager.default.removeItem(at: framesFolder)
                    return
                }
                // done == false means this detail level was rejected — fall back.
                lastError = "Detail \(detail) not supported on this device"
            } catch {
                lastError = error.localizedDescription
                break
            }
        }
        phase = .failed(lastError)
        try? FileManager.default.removeItem(at: framesFolder)
    }

    /// Returns true on success, false if the detail level was rejected and a
    /// fallback should be attempted. Throws on hard failures.
    private func runPhotogrammetryOnce(framesFolder: URL,
                                       detail: PhotogrammetrySession.Request.Detail) async throws -> Bool {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vista_obj_\(Int(Date().timeIntervalSince1970)).usdz")

        // Lazy sample sequence: one 12 MP sample in memory at a time.
        let loader = ObjectSampleLoader(framesFolder: framesFolder)
        let sampleURLs = loader.frameBaseNames()
        guard !sampleURLs.isEmpty else {
            throw NSError(domain: "Vista", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No captured photos found."])
        }
        let samples = sampleURLs.enumerated().lazy.compactMap { (i, base) in
            loader.loadSample(id: i, baseName: base)
        }

        var config = PhotogrammetrySession.Configuration()
        config.sampleOrdering = .sequential       // we orbit; neighbors overlap
        config.featureSensitivity = .normal
        config.isObjectMaskingEnabled = true      // use our masks + RealityKit's

        let pSession = try PhotogrammetrySession(input: samples, configuration: config)
        try pSession.process(requests: [.modelFile(url: tmpURL, detail: detail)])

        for try await output in pSession.outputs {
            switch output {
            case .processingComplete:
                let persisted: URL
                do {
                    persisted = try ScansStorage.saveCopy(of: tmpURL)
                    try? FileManager.default.removeItem(at: tmpURL)
                } catch {
                    persisted = tmpURL
                }
                phase = .ready(persisted)
                return true
            case .requestProgress(_, let fraction):
                phase = .processing(Float(fraction), "Building 3D model")
            case .requestError(_, let err):
                // Unsupported detail level -> signal fallback instead of failing.
                let msg = err.localizedDescription.lowercased()
                if msg.contains("detail") || msg.contains("support") {
                    pSession.cancel()
                    return false
                }
                throw err
            case .processingCancelled:
                throw NSError(domain: "Vista", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Processing cancelled"])
            default:
                break
            }
        }
        return false
    }

    private func upload(_ url: URL) async {
        phase = .uploading
        do {
            let suffix = String(Int.random(in: 1000...9999))
            let slug = "\(slugPrefix)obj-\(suffix)"
            let service = try UploadService.fromSettings(baseURLString: renderBaseURL, token: uploadToken)
            let result = try await service.uploadFile(url, slug: slug)
            phase = .uploaded(result)
        } catch let err as UploadError {
            phase = .failed(err.errorDescription ?? "\(err)")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Sample loading (lazy, per-frame enrichment)

/// Loads one enriched PhotogrammetrySample at a time from the capture folder.
/// Per frame on disk: <base>.jpg (12 MP), <base>_depth.bin (Float32 LE),
/// <base>_conf.bin (UInt8, saved for future cloud use), <base>_meta.json
/// (gravity + depth dims). Every enrichment is optional — failures degrade
/// the sample to image-only.
final class ObjectSampleLoader {
    private let framesFolder: URL
    private let ciContext = CIContext()

    struct FrameMetaSidecar: Codable {
        var gravityX: Double?
        var gravityY: Double?
        var gravityZ: Double?
        var depthWidth: Int?
        var depthHeight: Int?
    }

    init(framesFolder: URL) {
        self.framesFolder = framesFolder
    }

    /// Sorted base names (no extension) of all captured frames.
    func frameBaseNames() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: framesFolder,
                                                      includingPropertiesForKeys: nil) else {
            return []
        }
        return items
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func loadSample(id: Int, baseName: String) -> PhotogrammetrySample? {
        let jpgURL = framesFolder.appendingPathComponent("\(baseName).jpg")
        guard let imageBuffer = loadImagePixelBuffer(jpgURL) else { return nil }

        var sample = PhotogrammetrySample(id: id, image: imageBuffer)

        // Sidecar metadata (gravity + depth dims).
        let metaURL = framesFolder.appendingPathComponent("\(baseName)_meta.json")
        var meta: FrameMetaSidecar? = nil
        if let data = try? Data(contentsOf: metaURL) {
            meta = try? JSONDecoder().decode(FrameMetaSidecar.self, from: data)
        }

        if let m = meta, let gx = m.gravityX, let gy = m.gravityY, let gz = m.gravityZ {
            sample.gravity = CMAcceleration(x: gx, y: gy, z: gz)
        }

        if let m = meta, let dw = m.depthWidth, let dh = m.depthHeight, dw > 0, dh > 0 {
            let depthURL = framesFolder.appendingPathComponent("\(baseName)_depth.bin")
            if let depth = loadFloat32Buffer(depthURL, width: dw, height: dh) {
                sample.depthDataMap = depth
            }
        }

        // Automatic object isolation: Vision foreground-instance mask.
        if let mask = makeForegroundMask(jpgURL: jpgURL) {
            sample.objectMask = mask
        }

        return sample
    }

    // MARK: helpers

    private func loadImagePixelBuffer(_ url: URL) -> CVPixelBuffer? {
        guard let ci = CIImage(contentsOf: url) else { return nil }
        let w = Int(ci.extent.width), h = Int(ci.extent.height)
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        ciContext.render(ci, to: buffer)
        return buffer
    }

    private func loadFloat32Buffer(_ url: URL, width: Int, height: Int) -> CVPixelBuffer? {
        guard let data = try? Data(contentsOf: url),
              data.count == width * height * MemoryLayout<Float32>.size else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_DepthFloat32, nil, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let srcRow = width * MemoryLayout<Float32>.size
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let srcBase = src.baseAddress else { return }
            for row in 0..<height {
                memcpy(base.advanced(by: row * rowBytes),
                       srcBase.advanced(by: row * srcRow), srcRow)
            }
        }
        return buffer
    }

    /// Vision foreground-instance mask (iOS 17+): isolates the subject from
    /// the background with zero user input. Returns a OneComponent8 mask at
    /// image resolution, or nil if Vision finds no clear foreground subject.
    private func makeForegroundMask(jpgURL: URL) -> CVPixelBuffer? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(url: jpgURL, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler)
            return convertMaskToOneComponent8(maskBuffer)
        } catch {
            return nil
        }
    }

    /// Vision returns a OneComponent32Float mask; convert to OneComponent8.
    private func convertMaskToOneComponent8(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_OneComponent8 {
            return src
        }
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_OneComponent8, nil, &pb)
        guard let dst = pb else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        guard let sBase = CVPixelBufferGetBaseAddress(src),
              let dBase = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let sRow = CVPixelBufferGetBytesPerRow(src)
        let dRow = CVPixelBufferGetBytesPerRow(dst)
        for y in 0..<h {
            let sPtr = sBase.advanced(by: y * sRow).assumingMemoryBound(to: Float32.self)
            let dPtr = dBase.advanced(by: y * dRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                dPtr[x] = UInt8(max(0, min(255, sPtr[x] * 255)))
            }
        }
        return dst
    }
}

// MARK: - Fullscreen capture sheet (no box — aim, Start, orbit)

private struct ObjectCaptureSheet: View {
    let onFinish: (URL) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    @State private var arViewRef: ARView?
    @State private var coordinatorRef: ObjectFrameCoordinator?
    @State private var isFinishing = false
    @State private var isCapturing = false
    @State private var frameCount: Int = 0

    /// [T1-1] Coverage target: three height orbits + one close-up orbit.
    private let targetPhotos = 120

    var body: some View {
        ZStack {
            ObjectARRepresentable(
                onViewReady: { view, coord in
                    arViewRef = view
                    coordinatorRef = coord
                },
                onFrameCountUpdate: { fc in frameCount = fc }
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
                    statusBadge
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding()

                Spacer()

                primaryControls
                    .padding(.bottom, 32)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isCapturing {
            VStack(spacing: 2) {
                Text("\(frameCount) photos").font(.caption.monospaced())
                Text(guidanceText).font(.caption2.monospaced()).opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(frameCount >= targetPhotos ? .green.opacity(0.7) : .black.opacity(0.5),
                        in: Capsule())
        } else {
            Text("Aim at the object, then Start")
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private var guidanceText: String {
        switch frameCount {
        case 0..<30:    return "orbit low — full circle"
        case 30..<60:   return "orbit at eye level"
        case 60..<90:   return "orbit high, aim down"
        case 90..<120:  return "get CLOSE — fill the frame, orbit once"
        default:        return "great coverage — tap Done"
        }
    }

    @ViewBuilder
    private var primaryControls: some View {
        if !isCapturing {
            Button {
                isCapturing = true
                coordinatorRef?.beginCapture()
            } label: {
                Label("Start Capture", systemImage: "play.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(.blue, in: Capsule())
            }
        } else {
            Button {
                guard !isFinishing, let coord = coordinatorRef else { return }
                isFinishing = true
                let folder = coord.framesFolder
                coord.endCapture()
                arViewRef?.session.pause()
                onFinish(folder)
            } label: {
                if isFinishing {
                    ProgressView().tint(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.black.opacity(0.5), in: Capsule())
                } else {
                    Text("Done").font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 32).padding(.vertical, 10)
                        .background(.blue, in: Capsule())
                }
            }
        }
    }
}

// MARK: - UIViewRepresentable

private struct ObjectARRepresentable: UIViewRepresentable {
    let onViewReady: (ARView, ObjectFrameCoordinator) -> Void
    let onFrameCountUpdate: (Int) -> Void

    func makeCoordinator() -> ObjectFrameCoordinator {
        ObjectFrameCoordinator(onFrameCountUpdate: onFrameCountUpdate)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        // [T1-2] Without this, captureHighResolutionFrame can serve the plain
        // video resolution on some devices instead of the 12 MP still path.
        if let fmt = ARWorldTrackingConfiguration
            .recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = fmt
        }
        view.session.delegate = context.coordinator
        view.session.run(config)

        DispatchQueue.main.async { onViewReady(view, context.coordinator) }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) { }

    static func dismantleUIView(_ uiView: ARView, coordinator: ObjectFrameCoordinator) {
        coordinator.endCapture()
        uiView.session.pause()
    }
}

// MARK: - Coordinator (capture only — no box, no gestures)

final class ObjectFrameCoordinator: NSObject, ARSessionDelegate {
    let onFrameCountUpdate: (Int) -> Void

    let framesFolder: URL
    private(set) var frameCount = 0

    private var lastCapturedTransform: simd_float4x4?
    private let ciContext = CIContext()
    private let captureSerialQueue = DispatchQueue(label: "com.vista.obj-frame-capture",
                                                   qos: .userInitiated)
    private var saveInFlight = false
    private var captureStarted = false
    private var frameIndex = 0

    // [T1-1] Orbit-tuned cadence, tightened for the 120-photo target: the
    // rotation gate (~6 deg) fires through orbits, the translation gate
    // (~9 cm) covers height changes and the close-up pass.
    private let translationThresholdMeters: Float = 0.09
    private let rotationThresholdRadians: Float = 0.10
    private let maxPhotos = 250

    // [T1-3] Blur gate state: running best sharpness; frames scoring below
    // 30% of the best (after warmup) are rejected and recaptured.
    private var sharpBest: Float = 0

    private let motion = CMMotionManager()

    init(onFrameCountUpdate: @escaping (Int) -> Void) {
        self.onFrameCountUpdate = onFrameCountUpdate
        self.framesFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vista_obj_frames_\(Int(Date().timeIntervalSince1970))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: framesFolder,
                                                 withIntermediateDirectories: true)
        super.init()
    }

    func beginCapture() {
        captureStarted = true
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates()
        }
    }

    func endCapture() {
        captureStarted = false
        motion.stopDeviceMotionUpdates()
    }

    // MARK: AR session delegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard captureStarted, frameCount < maxPhotos else { return }

        let camTransform = frame.camera.transform
        let shouldCapture: Bool
        if let last = lastCapturedTransform {
            let posDelta = positionalDelta(camTransform, last)
            let rotDelta = rotationalDelta(camTransform, last)
            shouldCapture = (posDelta >= translationThresholdMeters)
                         || (rotDelta >= rotationThresholdRadians)
        } else {
            shouldCapture = true
        }

        guard shouldCapture && !saveInFlight else { return }
        saveInFlight = true
        lastCapturedTransform = camTransform

        // Snapshot LiDAR depth + confidence from THIS live frame — the
        // high-resolution photo frame below doesn't carry sceneDepth.
        var depthCopy: Data? = nil
        var confCopy: Data? = nil
        var depthW = 0, depthH = 0
        if let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth {
            (depthCopy, depthW, depthH) = Self.copyFloat32(sceneDepth.depthMap)
            if let conf = sceneDepth.confidenceMap {
                (confCopy, _, _) = Self.copyUInt8(conf)
            }
        }
        let gravity = motion.deviceMotion?.gravity

        // 12 MP photo via the high-resolution path.
        session.captureHighResolutionFrame { [weak self] hrFrame, _ in
            guard let self else { return }
            guard let hrFrame else {
                self.saveInFlight = false
                return
            }
            let pixelBuffer = hrFrame.capturedImage
            let idx = self.frameIndex
            self.frameIndex += 1

            self.captureSerialQueue.async { [weak self] in
                guard let self else { return }
                defer { self.saveInFlight = false }

                // [T1-3] Blur gate: reject motion-blurred photos so the
                // reconstructor only eats sharp input. Self-calibrating —
                // first few frames establish the scene's sharpness range.
                let score = Self.sharpnessScore(pixelBuffer, ciContext: self.ciContext)
                if self.sharpBest > 0, idx > 3, score < self.sharpBest * 0.3 {
                    DispatchQueue.main.async {
                        self.lastCapturedTransform = nil   // retry this spot now
                    }
                    return
                }
                self.sharpBest = max(self.sharpBest, score)

                let base = String(format: "frame_%05d", idx)
                let imgURL = self.framesFolder.appendingPathComponent("\(base).jpg")
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                guard let cg = self.ciContext.createCGImage(ciImage, from: ciImage.extent),
                      let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.92) else {
                    return
                }
                do {
                    try jpeg.write(to: imgURL)
                } catch {
                    return
                }

                if let d = depthCopy {
                    try? d.write(to: self.framesFolder
                        .appendingPathComponent("\(base)_depth.bin"))
                }
                if let c = confCopy {
                    try? c.write(to: self.framesFolder
                        .appendingPathComponent("\(base)_conf.bin"))
                }
                let meta = ObjectSampleLoader.FrameMetaSidecar(
                    gravityX: gravity?.x, gravityY: gravity?.y, gravityZ: gravity?.z,
                    depthWidth: depthCopy != nil ? depthW : nil,
                    depthHeight: depthCopy != nil ? depthH : nil
                )
                if let metaData = try? JSONEncoder().encode(meta) {
                    try? metaData.write(to: self.framesFolder
                        .appendingPathComponent("\(base)_meta.json"))
                }

                DispatchQueue.main.async {
                    self.frameCount += 1
                    self.onFrameCountUpdate(self.frameCount)
                }
            }
        }
    }

    // MARK: [T1-3] sharpness scoring

    /// Laplacian-variance sharpness on a ~256px grayscale thumbnail —
    /// cheap (<5 ms) and monotonic with focus/motion blur.
    private static func sharpnessScore(_ pb: CVPixelBuffer,
                                       ciContext: CIContext) -> Float {
        let ci = CIImage(cvPixelBuffer: pb)
        guard ci.extent.width > 0 else { return 0 }
        let scale = 256.0 / ci.extent.width
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 2, h > 2, let cg = ciContext.createCGImage(small, from: small.extent)
        else { return 0 }
        var gray = [UInt8](repeating: 0, count: w * h)
        let ok = gray.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var sum = 0.0, sumsq = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Int(gray[y * w + x])
                let lap = 4 * c - Int(gray[y * w + x - 1]) - Int(gray[y * w + x + 1])
                          - Int(gray[(y - 1) * w + x]) - Int(gray[(y + 1) * w + x])
                let v = Double(lap)
                sum += v; sumsq += v * v
            }
        }
        let n = Double((w - 2) * (h - 2))
        let mean = sum / n
        return Float(sumsq / n - mean * mean)
    }

    // MARK: pixel buffer copies (tight, row-aware)

    private static func copyFloat32(_ buffer: CVPixelBuffer) -> (Data?, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (nil, 0, 0) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let dstRow = w * MemoryLayout<Float32>.size
        var data = Data(count: dstRow * h)
        data.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            guard let dstBase = dst.baseAddress else { return }
            for row in 0..<h {
                memcpy(dstBase.advanced(by: row * dstRow),
                       base.advanced(by: row * rowBytes), dstRow)
            }
        }
        return (data, w, h)
    }

    private static func copyUInt8(_ buffer: CVPixelBuffer) -> (Data?, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (nil, 0, 0) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(count: w * h)
        data.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            guard let dstBase = dst.baseAddress else { return }
            for row in 0..<h {
                memcpy(dstBase.advanced(by: row * w),
                       base.advanced(by: row * rowBytes), w)
            }
        }
        return (data, w, h)
    }

    private func positionalDelta(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let pa = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        return simd_distance(pa, pb)
    }
    private func rotationalDelta(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let qa = simd_quatf(a); let qb = simd_quatf(b)
        let dot = abs(simd_dot(qa, qb))
        let clamped = min(max(dot, -1), 1)
        return 2 * acos(clamped)
    }
}

#Preview {
    ObjectCaptureView()
}
