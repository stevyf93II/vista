//
//  ObjectCaptureView.swift
//  Vista
//
//  Object Capture v3 (2026-08-18) — LARGE-OBJECT (vehicle) capture.
//
//  WHAT CHANGED vs v2:
//  [T2-1] SECTOR BUDGET. v2 had a hard `maxPhotos = 250` with a 9 cm / 6 deg
//         cadence. Those numbers were tuned for a small object at ~0.5 m:
//         one orbit is ~3 m of walking -> ~35 photos -> 4 orbits fits in 250.
//         Around a CAR at ~2 m standoff one orbit is ~20 m of walking, so the
//         9 cm gate alone spends ~220 photos on the FIRST orbit and the cap
//         silently kills capture partway round. The far side never gets
//         photographed, so it never reconstructs. Fix: the bearing angle
//         around the object is divided into 24 sectors of 15 deg and each
//         sector gets its own quota. The budget can no longer be eaten by
//         wherever you started. Standing still stops consuming frames.
//  [T2-2] OBJECT CENTER from LiDAR at Start (median central depth along the
//         camera forward ray) -> bearing = atan2 around that point. If depth
//         is unavailable the old pure translation/rotation cadence is used
//         unchanged, so behaviour degrades to v2 rather than breaking.
//  [T2-3] CAPTURE SCALE picker: .small (v2 numbers, 250 cap) or
//         .vehicle (500 cap, 12 cm / 6 deg cadence, sector budget on).
//  [T2-4] Vision foreground masking is DISABLED in .vehicle mode. A
//         VNGenerateForegroundInstanceMaskRequest on a frame where a 4.5 m
//         car overflows the frame returns an instance that is a PART of the
//         car (a wheel, a seat) — feeding that as objectMask deletes the rest
//         of the panel from that view. Small objects keep the mask.
//         The choice is written to capture_config.json in the frames folder
//         so ObjectSampleLoader honours it without extra plumbing.
//  [T2-5] Coverage HUD is bearing-based, not frame-count-based: it reports
//         how much of the 360 you have actually walked, and says so out loud
//         when the budget is spent instead of going quiet.
//
//  Unchanged from v2: 12 MP captureHighResolutionFrame + recommended hi-res
//  format, per-frame depth/conf/gravity sidecars, Laplacian blur gate at 30%
//  of running best, iOS 17 sequence-of-samples PhotogrammetrySession,
//  detail .reduced (iOS ceiling; .full is macOS-only).
//

import SwiftUI
import ARKit
import RealityKit
import CoreMotion
import Vision
import simd
import UIKit
import CoreImage

// MARK: - Capture scale

enum CaptureScale: String, Codable, CaseIterable, Identifiable {
    case small      // mug, tool, part — v2 behaviour
    case vehicle    // car, trailer, RV, anything you walk around

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small:   return "Small object"
        case .vehicle: return "Vehicle / large"
        }
    }

    var subtitle: String {
        switch self {
        case .small:   return "Fits on a table. Orbit at arm's length."
        case .vehicle: return "Car, trailer, RV. You walk around it."
        }
    }

    var maxPhotos: Int {
        switch self {
        case .small:   return 250
        case .vehicle: return 500
        }
    }

    var translationThresholdMeters: Float {
        switch self {
        case .small:   return 0.09
        case .vehicle: return 0.12
        }
    }

    var rotationThresholdRadians: Float { 0.10 }

    /// Sector budget only makes sense once the object is big enough that you
    /// orbit it on foot.
    var usesSectorBudget: Bool {
        switch self {
        case .small:   return false
        case .vehicle: return true
        }
    }

    /// [T2-4] Vision foreground-instance masks help on small objects and hurt
    /// when the subject overflows the frame.
    var usesForegroundMask: Bool {
        switch self {
        case .small:   return true
        case .vehicle: return false
        }
    }

    var guidanceCopy: String {
        switch self {
        case .small:
            return "Orbit slowly at three heights — low, level, high — then a close-up pass filling the frame."
        case .vehicle:
            return "Walk a full lap at waist height, then a second lap at chest height aiming slightly down, then a third lap close in on the panels. Finish the lap — the app now saves budget for the far side."
        }
    }
}

/// Written into the frames folder so the sample loader knows how the capture
/// was configured without threading state through the photogrammetry call.
struct CaptureConfigSidecar: Codable {
    var scale: String
    var usesForegroundMask: Bool
}

// MARK: - Main view

struct ObjectCaptureView: View {
    @AppStorage("renderBaseURL") private var renderBaseURL: String = ""
    @AppStorage("uploadToken") private var uploadToken: String = ""
    @AppStorage("slugPrefix") private var slugPrefix: String = "vista-"
    @AppStorage("objectCaptureScale") private var scaleRaw: String = CaptureScale.small.rawValue

    @State private var phase: Phase = .idle
    @State private var showCaptureSheet = false

    private var scale: CaptureScale {
        CaptureScale(rawValue: scaleRaw) ?? .small
    }

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
                    Text("Aim at the object and tap Start. \(scale.guidanceCopy) Blurry shots are rejected automatically. 12 MP photos plus LiDAR depth feed on-device photogrammetry (~5–10 min). No box to place; isolation is automatic.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    scalePicker

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
                scale: scale,
                onFinish: { framesFolder in
                    showCaptureSheet = false
                    Task { await runPhotogrammetry(framesFolder: framesFolder) }
                },
                onCancel: { showCaptureSheet = false },
                onError: handleScanError
            )
        }
    }

    // [T2-3] Scale picker. The default stays .small so existing muscle memory
    // and existing small-object results are untouched.
    private var scalePicker: some View {
        VStack(spacing: 6) {
            Picker("Size", selection: Binding(
                get: { scale },
                set: { scaleRaw = $0.rawValue }
            )) {
                ForEach(CaptureScale.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)

            Text(scale.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                Text("Photogrammetry with depth: ~5–10 minutes on a small object, longer on a vehicle. Keep the app open.")
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

    // MARK: - Photogrammetry (samples input: depth + gravity + optional masks)

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
        // Masking stays enabled as a session capability; whether a per-sample
        // mask is actually supplied is decided by the loader from the sidecar.
        config.isObjectMaskingEnabled = loader.usesForegroundMask

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
/// (gravity + depth dims). Folder-level: capture_config.json. Every
/// enrichment is optional — failures degrade the sample to image-only.
final class ObjectSampleLoader {
    private let framesFolder: URL
    private let ciContext = CIContext()

    /// [T2-4] Read once from capture_config.json. Defaults to true so a
    /// folder written by an older build behaves exactly like v2.
    let usesForegroundMask: Bool

    struct FrameMetaSidecar: Codable {
        var gravityX: Double?
        var gravityY: Double?
        var gravityZ: Double?
        var depthWidth: Int?
        var depthHeight: Int?
    }

    init(framesFolder: URL) {
        self.framesFolder = framesFolder
        let cfgURL = framesFolder.appendingPathComponent("capture_config.json")
        if let data = try? Data(contentsOf: cfgURL),
           let cfg = try? JSONDecoder().decode(CaptureConfigSidecar.self, from: data) {
            self.usesForegroundMask = cfg.usesForegroundMask
        } else {
            self.usesForegroundMask = true
        }
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
        // [T2-4] Skipped for vehicle-scale captures — see header.
        if usesForegroundMask, let mask = makeForegroundMask(jpgURL: jpgURL) {
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
    let scale: CaptureScale
    let onFinish: (URL) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    @State private var arViewRef: ARView?
    @State private var coordinatorRef: ObjectFrameCoordinator?
    @State private var isFinishing = false
    @State private var isCapturing = false
    @State private var frameCount: Int = 0
    @State private var coverage: Float = 0      // [T2-5] fraction of 360 seen
    @State private var budgetSpent: Bool = false

    var body: some View {
        ZStack {
            ObjectARRepresentable(
                scale: scale,
                onViewReady: { view, coord in
                    arViewRef = view
                    coordinatorRef = coord
                },
                onProgressUpdate: { fc, cov, spent in
                    frameCount = fc
                    coverage = cov
                    budgetSpent = spent
                }
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

                if isCapturing && scale.usesSectorBudget {
                    coverageBar
                        .padding(.horizontal, 40)
                        .padding(.bottom, 12)
                }

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
            .background(badgeColor, in: Capsule())
        } else {
            Text("Aim at the \(scale == .vehicle ? "vehicle" : "object"), then Start")
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private var badgeColor: Color {
        if budgetSpent { return .orange.opacity(0.8) }
        if coverage >= 0.95 { return .green.opacity(0.7) }
        return .black.opacity(0.5)
    }

    /// [T2-5] A real coverage read-out. The old version guessed progress from
    /// the photo count, which is exactly the assumption that hid the bug.
    private var coverageBar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(coverage >= 0.95 ? Color.green : Color.blue)
                        .frame(width: geo.size.width * CGFloat(coverage))
                }
            }
            .frame(height: 6)
            Text("\(Int(coverage * 100))% of the way around")
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var guidanceText: String {
        if budgetSpent { return "photo budget full — tap Done" }
        switch scale {
        case .vehicle:
            if coverage < 0.95 { return "keep walking the lap" }
            return "lap done — go again, higher / closer"
        case .small:
            switch frameCount {
            case 0..<30:    return "orbit low — full circle"
            case 30..<60:   return "orbit at eye level"
            case 60..<90:   return "orbit high, aim down"
            case 90..<120:  return "get CLOSE — fill the frame, orbit once"
            default:        return "great coverage — tap Done"
            }
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
    let scale: CaptureScale
    let onViewReady: (ARView, ObjectFrameCoordinator) -> Void
    let onProgressUpdate: (Int, Float, Bool) -> Void

    func makeCoordinator() -> ObjectFrameCoordinator {
        ObjectFrameCoordinator(scale: scale, onProgressUpdate: onProgressUpdate)
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
    let onProgressUpdate: (Int, Float, Bool) -> Void

    let framesFolder: URL
    private(set) var frameCount = 0

    private let scale: CaptureScale

    private var lastCapturedTransform: simd_float4x4?
    private let ciContext = CIContext()
    private let captureSerialQueue = DispatchQueue(label: "com.vista.obj-frame-capture",
                                                   qos: .userInitiated)
    private var saveInFlight = false
    private var captureStarted = false
    private var frameIndex = 0

    // Cadence gates (per scale). The rotation gate fires through orbits, the
    // translation gate covers height changes and the close-up pass.
    private let translationThresholdMeters: Float
    private let rotationThresholdRadians: Float
    private let maxPhotos: Int

    // [T2-1] Sector budget. 24 sectors of 15 deg of bearing around the object
    // center. Each sector may contribute at most `perSectorQuota` photos, so
    // the first side you walk cannot spend the whole budget.
    private static let sectorCount = 24
    private var sectorCounts = [Int](repeating: 0, count: ObjectFrameCoordinator.sectorCount)
    private let perSectorQuota: Int
    private let usesSectorBudget: Bool

    // [T2-2] Object center, estimated once at Start from LiDAR depth.
    private var objectCenter: SIMD3<Float>?
    private var centerAttempts = 0

    // [T1-3] Blur gate state: running best sharpness; frames scoring below
    // 30% of the best (after warmup) are rejected and recaptured.
    private var sharpBest: Float = 0

    private let motion = CMMotionManager()

    init(scale: CaptureScale,
         onProgressUpdate: @escaping (Int, Float, Bool) -> Void) {
        self.scale = scale
        self.onProgressUpdate = onProgressUpdate
        self.translationThresholdMeters = scale.translationThresholdMeters
        self.rotationThresholdRadians = scale.rotationThresholdRadians
        self.maxPhotos = scale.maxPhotos
        self.usesSectorBudget = scale.usesSectorBudget
        // Ceiling-divide so the quotas can actually reach the cap.
        self.perSectorQuota = max(1, Int(ceil(Double(scale.maxPhotos)
                                              / Double(ObjectFrameCoordinator.sectorCount))))
        self.framesFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vista_obj_frames_\(Int(Date().timeIntervalSince1970))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: framesFolder,
                                                 withIntermediateDirectories: true)
        super.init()
        writeCaptureConfig()
    }

    private func writeCaptureConfig() {
        let cfg = CaptureConfigSidecar(scale: scale.rawValue,
                                       usesForegroundMask: scale.usesForegroundMask)
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: framesFolder.appendingPathComponent("capture_config.json"))
        }
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

    /// Fraction of the 360 that has at least one photo in it.
    private var coverageFraction: Float {
        guard usesSectorBudget else { return 0 }
        let hit = sectorCounts.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        return Float(hit) / Float(Self.sectorCount)
    }

    private var budgetSpent: Bool {
        frameCount >= maxPhotos
    }

    private func publishProgress() {
        let fc = frameCount
        let cov = coverageFraction
        let spent = budgetSpent
        DispatchQueue.main.async { self.onProgressUpdate(fc, cov, spent) }
    }

    // MARK: AR session delegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard captureStarted, frameCount < maxPhotos else { return }

        // [T2-2] Estimate the object center once, from the first few frames.
        if usesSectorBudget, objectCenter == nil, centerAttempts < 30 {
            centerAttempts += 1
            objectCenter = Self.estimateObjectCenter(frame: frame)
        }

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

        // [T2-1] Sector budget check. If this bearing is already full, skip
        // the photo but DO advance lastCapturedTransform so we re-evaluate
        // after the next step rather than firing every frame.
        var sectorIndex: Int? = nil
        if usesSectorBudget, let center = objectCenter {
            let idx = Self.sectorIndex(cameraTransform: camTransform, center: center)
            if sectorCounts[idx] >= perSectorQuota {
                lastCapturedTransform = camTransform
                publishProgress()
                return
            }
            sectorIndex = idx
        }

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
                    if let s = sectorIndex { self.sectorCounts[s] += 1 }
                    self.publishProgress()
                }
            }
        }
    }

    // MARK: [T2-2] object center + [T2-1] bearing sectors

    /// Median of the valid central LiDAR depths, projected along the camera
    /// forward axis. Rough on purpose — it only has to be good enough to make
    /// bearing sectors meaningful, and a car-sized object tolerates ~0.5 m of
    /// center error at 24 sectors. Returns nil when depth is unavailable, in
    /// which case the sector budget stays off and v2 cadence applies.
    static func estimateObjectCenter(frame: ARFrame) -> SIMD3<Float>? {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let buf = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        guard w > 8, h > 8, let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buf)

        // Central third of the depth map.
        let x0 = w / 3, x1 = 2 * w / 3
        let y0 = h / 3, y1 = 2 * h / 3
        var samples: [Float] = []
        samples.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in x0..<x1 {
                let d = row[x]
                if d.isFinite, d > 0.15, d < 8.0 { samples.append(d) }
            }
        }
        guard samples.count > 32 else { return nil }
        samples.sort()
        let median = samples[samples.count / 2]

        let t = frame.camera.transform
        let camPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // ARKit camera looks down -Z.
        let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        return camPos + forward * median
    }

    /// Which 15-degree bearing sector the camera currently occupies, measured
    /// around the object center in the horizontal plane.
    static func sectorIndex(cameraTransform: simd_float4x4, center: SIMD3<Float>) -> Int {
        let p = SIMD3<Float>(cameraTransform.columns.3.x,
                             cameraTransform.columns.3.y,
                             cameraTransform.columns.3.z)
        let dx = p.x - center.x
        let dz = p.z - center.z
        var ang = atan2(dz, dx)                    // -pi ... pi
        if ang < 0 { ang += 2 * Float.pi }         // 0 ... 2pi
        let idx = Int(ang / (2 * Float.pi) * Float(sectorCount))
        return min(max(idx, 0), sectorCount - 1)
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
