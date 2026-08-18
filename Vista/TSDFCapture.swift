//
//  TSDFCapture.swift
//  Vista
//
//  TSDF Phase 1 — per-frame data structures + on-disk save format.
//
//  Disk format per frame (frames/<idx>/):
//    depth.bin    — 256x192 Float32 little-endian, meters (smoothedSceneDepth)
//    conf.bin     — 256x192 UInt8 (ARKit confidence values 0/1/2)
//    rgb.jpg      — frame.capturedImage encoded as JPEG q=0.92
//    meta.json    — pose + intrinsics + dims + trackingState (FrameMeta)
//
//  Coordinate system: ARKit right-handed, +Y up, camera looks down -Z.
//  Intrinsics in meta.json correspond to the FULL captured image resolution
//  (e.g. 1920×1440), NOT the 256×192 depth map. Downstream code must rescale
//  before unprojecting depth pixels.
//
//  WHY THE FORMAT MATCHES andyzeng/tsdf-fusion-python:
//    Cross-validation. Phase 1 outputs can be transferred to the Lenovo and
//    run through the Python reference TSDF before we write any Swift TSDF.
//    If the Python pipeline produces a clean mesh, our capture is correct.
//    If it produces garbage, we have an intrinsics/sign/pose bug to fix
//    BEFORE touching Phase 2 math.
//

import Foundation
import ARKit
import CoreVideo
import CoreImage
import UIKit
import simd

/// Per-frame snapshot with deep-copied buffers — safe to hold across async work.
struct FrameSnapshot {
    let timestamp: TimeInterval
    let depth: CVPixelBuffer        // R32Float, 256x192, meters
    let confidence: CVPixelBuffer   // R8, 256x192, ARKit confidence 0..2
    let rgb: CVPixelBuffer          // YCbCr biplanar, full resolution
    let cameraTransform: simd_float4x4  // camera -> world (ARKit)
    let intrinsics: simd_float3x3       // for rgb resolution
    let imageWidth: Int
    let imageHeight: Int
    let trackingState: String           // ARCamera.trackingState at capture
}

/// On-disk metadata sidecar per frame.
struct FrameMeta: Codable {
    let timestamp: Double
    let imageWidth: Int
    let imageHeight: Int
    let depthWidth: Int   // always 256 on iPhone 12 Pro family
    let depthHeight: Int  // always 192 on iPhone 12 Pro family
    let cameraTransformRowMajor: [[Float]]  // 4x4 row-major
    let intrinsicsRowMajor: [[Float]]       // 3x3 row-major, for image resolution
    let coordinateSystem: String  // "ARKit_RH_Y_up"
    let depthUnits: String        // "meters"
    // Pose quality at capture: "normal", "notAvailable",
    // "limited.relocalizing", etc. Optional so old metas still decode.
    // Cloud rebuild drops non-normal frames before fusion (pose-drift guard).
    let trackingState: String?
}

/// Snapshotter: extract everything needed from an ARFrame, deep-copying
/// CVPixelBuffers so the ARSession buffer pool is not retained.
///
/// MANDATORY DEEP COPY — per Waley-Z/ios-depth-point-cloud README:
///   "If ARFrame currentFrame is passed into time-consuming async tasks
///    like converting data formats or saving files to disks, the memory
///    pool used by ARFrame is retained and no more frames can be written
///    to the pool."
/// Symptom: `ARSessionDelegate is retaining XX ARFrames` log + capture stalls.
enum FrameSnapshotter {
    static func snapshot(from frame: ARFrame) -> FrameSnapshot? {
        // Prefer smoothedSceneDepth (temporally stabilized across frames).
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return nil
        }
        guard
            let depthCopy = deepCopy(sceneDepth.depthMap),
            let confCopy = sceneDepth.confidenceMap.flatMap(deepCopy),
            let rgbCopy = deepCopy(frame.capturedImage)
        else { return nil }

        return FrameSnapshot(
            timestamp: frame.timestamp,
            depth: depthCopy,
            confidence: confCopy,
            rgb: rgbCopy,
            cameraTransform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageWidth: CVPixelBufferGetWidth(rgbCopy),
            imageHeight: CVPixelBufferGetHeight(rgbCopy),
            trackingState: trackingStateString(frame.camera.trackingState)
        )
    }

    /// Stringify ARCamera.trackingState for the on-disk meta.
    static func trackingStateString(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal:       return "normal"
        case .notAvailable: return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing:         return "limited.initializing"
            case .relocalizing:         return "limited.relocalizing"
            case .excessiveMotion:      return "limited.excessiveMotion"
            case .insufficientFeatures: return "limited.insufficientFeatures"
            @unknown default:           return "limited.unknown"
            }
        @unknown default:   return "unknown"
        }
    }

    /// Deep copy a CVPixelBuffer into a new buffer with the same format.
    /// Handles both planar (YCbCr) and non-planar (depth/confidence) buffers.
    private static func deepCopy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(src)
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        var dst: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height, format,
            attrs as CFDictionary,
            &dst
        )
        guard status == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }

        if CVPixelBufferIsPlanar(src) {
            let n = CVPixelBufferGetPlaneCount(src)
            for i in 0..<n {
                guard let sBase = CVPixelBufferGetBaseAddressOfPlane(src, i),
                      let dBase = CVPixelBufferGetBaseAddressOfPlane(dst, i) else {
                    return nil
                }
                let h = CVPixelBufferGetHeightOfPlane(src, i)
                let sRow = CVPixelBufferGetBytesPerRowOfPlane(src, i)
                let dRow = CVPixelBufferGetBytesPerRowOfPlane(dst, i)
                let rowCopy = min(sRow, dRow)
                for r in 0..<h {
                    memcpy(dBase + r * dRow, sBase + r * sRow, rowCopy)
                }
            }
        } else {
            guard let sBase = CVPixelBufferGetBaseAddress(src),
                  let dBase = CVPixelBufferGetBaseAddress(dst) else {
                return nil
            }
            let h = CVPixelBufferGetHeight(src)
            let sRow = CVPixelBufferGetBytesPerRow(src)
            let dRow = CVPixelBufferGetBytesPerRow(dst)
            let rowCopy = min(sRow, dRow)
            for r in 0..<h {
                memcpy(dBase + r * dRow, sBase + r * sRow, rowCopy)
            }
        }
        return dst
    }
}

/// Writes a FrameSnapshot to disk in the documented per-frame folder format.
enum FrameDiskWriter {
    private static let ciContext = CIContext()

    /// Returns the per-frame folder URL on success.
    @discardableResult
    static func write(_ snapshot: FrameSnapshot, index: Int, framesRoot: URL) throws -> URL {
        let folder = framesRoot.appendingPathComponent(String(format: "%05d", index),
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)

        try writeDepthFloat32(snapshot.depth,
                              to: folder.appendingPathComponent("depth.bin"))
        try writeConfidenceUInt8(snapshot.confidence,
                                 to: folder.appendingPathComponent("conf.bin"))
        try writeRGBJPEG(snapshot.rgb,
                         to: folder.appendingPathComponent("rgb.jpg"))
        try writeMeta(snapshot,
                      to: folder.appendingPathComponent("meta.json"))
        return folder
    }

    private static func writeDepthFloat32(_ buffer: CVPixelBuffer, to url: URL) throws {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw NSError(domain: "FrameDiskWriter", code: 1)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: w * h * 4)
        for row in 0..<h {
            let rowPtr = base.advanced(by: row * bytesPerRow)
            data.append(Data(bytes: rowPtr, count: w * 4))
        }
        try data.write(to: url)
    }

    private static func writeConfidenceUInt8(_ buffer: CVPixelBuffer, to url: URL) throws {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw NSError(domain: "FrameDiskWriter", code: 2)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: w * h)
        for row in 0..<h {
            let rowPtr = base.advanced(by: row * bytesPerRow)
            data.append(Data(bytes: rowPtr, count: w))
        }
        try data.write(to: url)
    }

    private static func writeRGBJPEG(_ buffer: CVPixelBuffer, to url: URL) throws {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw NSError(domain: "FrameDiskWriter", code: 3)
        }
        let ui = UIImage(cgImage: cg)
        guard let jpeg = ui.jpegData(compressionQuality: 0.92) else {
            throw NSError(domain: "FrameDiskWriter", code: 4)
        }
        try jpeg.write(to: url)
    }

    private static func writeMeta(_ s: FrameSnapshot, to url: URL) throws {
        let meta = FrameMeta(
            timestamp: s.timestamp,
            imageWidth: s.imageWidth,
            imageHeight: s.imageHeight,
            depthWidth: CVPixelBufferGetWidth(s.depth),
            depthHeight: CVPixelBufferGetHeight(s.depth),
            cameraTransformRowMajor: matrix4x4ToRows(s.cameraTransform),
            intrinsicsRowMajor: matrix3x3ToRows(s.intrinsics),
            coordinateSystem: "ARKit_RH_Y_up",
            depthUnits: "meters",
            trackingState: s.trackingState
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: url)
    }

    // simd_float4x4 is column-major in memory; emit row-major for JSON
    // portability with the reference Python pipeline.
    private static func matrix4x4ToRows(_ m: simd_float4x4) -> [[Float]] {
        return [
            [m.columns.0[0], m.columns.1[0], m.columns.2[0], m.columns.3[0]],
            [m.columns.0[1], m.columns.1[1], m.columns.2[1], m.columns.3[1]],
            [m.columns.0[2], m.columns.1[2], m.columns.2[2], m.columns.3[2]],
            [m.columns.0[3], m.columns.1[3], m.columns.2[3], m.columns.3[3]],
        ]
    }
    private static func matrix3x3ToRows(_ m: simd_float3x3) -> [[Float]] {
        return [
            [m.columns.0[0], m.columns.1[0], m.columns.2[0]],
            [m.columns.0[1], m.columns.1[1], m.columns.2[1]],
            [m.columns.0[2], m.columns.1[2], m.columns.2[2]],
        ]
    }
}
