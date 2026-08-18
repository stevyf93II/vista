//
//  NaiveCloudExporter.swift
//  Vista
//
//  TSDF Phase 1: walk a per-frame folder dump (depth.bin / conf.bin / rgb.jpg /
//  meta.json) and write a single accumulated point cloud as binary PLY.
//
//  This is the NAIVE BASELINE — what the build spec explicitly calls out as
//  "what most DIY builds do": unproject every depth pixel, color it from RGB,
//  filter by confidence/depth, dump to one growing cloud. Surfaces will be
//  doubled/offset, drift will bend walls. That's expected.
//
//  THE POINT OF HAVING THIS FIRST:
//  - Validates intrinsics rescale (256/imageWidth for fx, fy, cx, cy).
//  - Validates ARKit sign convention (camera looks -Z; we negate Y, Z).
//  - Validates pose-to-world matrix application.
//  - Lets us cross-check on the Lenovo against andyzeng/tsdf-fusion-python
//    BEFORE writing Swift TSDF — if Python's pipeline produces a clean mesh
//    from our frames, our data plumbing is correct. If garbage, fix here
//    first.
//
//  Phase 2 REPLACES this entirely with TSDF integration. Keep this around
//  until Phase 3 ships, then it can be deleted.
//
//  HOTFIX 2026-06-07 (TestFlight crash log Vista: Data.reserveCapacity(_:) + 8):
//   - Cap input frames at 60 (subsample if more captured). 500+ frames was
//     accumulating ~6.5M points and crashing inside Data.reserveCapacity
//     during PLY write.
//   - pixelStride 2 → 4 so each frame contributes ~25% as many points.
//   - autoreleasepool per frame so CGContext / UIImage / depth arrays release
//     between iterations.
//   - All 500+ captured frames REMAIN on disk via FrameDiskWriter for Phase 2.
//     Only this naive baseline subsamples.
//

import Foundation
import CoreGraphics
import ImageIO
import UIKit
import simd

enum NaiveCloudExporter {

    struct Config {
        var pixelStride: Int = 4        // every Nth depth pixel; 4 gives 64x48 points/frame
        var minConfidence: UInt8 = 2    // .high only; loosen to 1 if scans come out sparse
        var depthMin: Float = 0.3       // ARKit LiDAR garbage <0.3m
        var depthMax: Float = 4.5       // unreliable >5m
        var maxFrames: Int = 60         // cap input frames (matches USDZ cap)
    }

    /// Walk frames folder, optionally subsample to maxFrames, unproject each
    /// frame's depth pixels into world space, write a single accumulated PLY.
    @discardableResult
    static func export(framesRoot: URL,
                       to url: URL,
                       config: Config = Config()) throws -> URL {
        let fm = FileManager.default
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []
        let decoder = JSONDecoder()

        let allFolders = try fm.contentsOfDirectory(
            at: framesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Stride-subsample to maxFrames so we keep orbit coverage rather than
        // slicing the start or end of the capture.
        let folders: [URL]
        if allFolders.count > config.maxFrames {
            var picked: [URL] = []
            picked.reserveCapacity(config.maxFrames)
            let step = Double(allFolders.count) / Double(config.maxFrames)
            for i in 0..<config.maxFrames {
                let idx = min(allFolders.count - 1, Int(Double(i) * step))
                picked.append(allFolders[idx])
            }
            folders = picked
        } else {
            folders = allFolders
        }

        // Pre-reserve based on the cap so the positions/colors arrays don't
        // resize during the loop. 60 frames * 3072 points = 184,320 worst case.
        let maxPointsPerFrame = (256 / config.pixelStride) * (192 / config.pixelStride)
        let expected = folders.count * maxPointsPerFrame
        positions.reserveCapacity(expected)
        colors.reserveCapacity(expected)

        for folder in folders {
            autoreleasepool {
                processFrame(
                    folder: folder,
                    decoder: decoder,
                    config: config,
                    positions: &positions,
                    colors: &colors
                )
            }
        }

        try PLYBinaryExporter.writePointCloud(
            positions: positions, colors: colors, to: url
        )
        return url
    }

    /// Per-frame work. Pulled into its own function so the autoreleasepool
    /// in the caller actually contains the temporary CGContext / UIImage /
    /// depth array allocations.
    private static func processFrame(
        folder: URL,
        decoder: JSONDecoder,
        config: Config,
        positions: inout [SIMD3<Float>],
        colors: inout [SIMD3<UInt8>]
    ) {
        let metaURL = folder.appendingPathComponent("meta.json")
        let depthURL = folder.appendingPathComponent("depth.bin")
        let confURL = folder.appendingPathComponent("conf.bin")
        let rgbURL = folder.appendingPathComponent("rgb.jpg")

        guard
            let metaData = try? Data(contentsOf: metaURL),
            let meta = try? decoder.decode(FrameMeta.self, from: metaData),
            let depthData = try? Data(contentsOf: depthURL),
            let confData = try? Data(contentsOf: confURL),
            let rgbImg = UIImage(contentsOfFile: rgbURL.path)?.cgImage
        else { return }

        let dw = meta.depthWidth
        let dh = meta.depthHeight
        guard depthData.count == dw * dh * 4 else { return }
        guard confData.count == dw * dh else { return }

        // Rescale intrinsics for depth resolution.
        // CRITICAL: ARKit intrinsics are for the captured image (e.g. 1920×1440),
        // not the 256×192 depth map. Without rescaling, all unprojected points
        // land miles off-axis.
        let scaleX = Float(dw) / Float(meta.imageWidth)
        let scaleY = Float(dh) / Float(meta.imageHeight)
        let fx = meta.intrinsicsRowMajor[0][0] * scaleX
        let fy = meta.intrinsicsRowMajor[1][1] * scaleY
        let cx = meta.intrinsicsRowMajor[0][2] * scaleX
        let cy = meta.intrinsicsRowMajor[1][2] * scaleY

        // Build camera->world 4×4.
        let m = meta.cameraTransformRowMajor
        let camToWorld = simd_float4x4(rows: [
            SIMD4<Float>(m[0][0], m[0][1], m[0][2], m[0][3]),
            SIMD4<Float>(m[1][0], m[1][1], m[1][2], m[1][3]),
            SIMD4<Float>(m[2][0], m[2][1], m[2][2], m[2][3]),
            SIMD4<Float>(m[3][0], m[3][1], m[3][2], m[3][3]),
        ])

        // Rasterize RGB to RGBA8 for fast pixel sampling.
        let rgbW = rgbImg.width
        let rgbH = rgbImg.height
        guard let rgbCtx = CGContext(
            data: nil,
            width: rgbW, height: rgbH,
            bitsPerComponent: 8,
            bytesPerRow: rgbW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return }
        rgbCtx.draw(rgbImg, in: CGRect(x: 0, y: 0, width: rgbW, height: rgbH))
        guard let rgbBase = rgbCtx.data else { return }
        let rgbBytes = rgbBase.bindMemory(to: UInt8.self, capacity: rgbW * rgbH * 4)

        // Copy depth/conf into Swift arrays for fast indexed access.
        let depthFloats: [Float] = depthData.withUnsafeBytes { raw -> [Float] in
            Array(raw.bindMemory(to: Float.self))
        }
        let confBytes: [UInt8] = Array(confData)

        for v in stride(from: 0, to: dh, by: config.pixelStride) {
            for u in stride(from: 0, to: dw, by: config.pixelStride) {
                let idx = v * dw + u
                let conf = confBytes[idx]
                if conf < config.minConfidence { continue }
                let d = depthFloats[idx]
                if !d.isFinite || d < config.depthMin || d > config.depthMax {
                    continue
                }

                // ARKit camera frame: +X right, +Y up, -Z forward.
                // Pixel (u,v) is (right, down), so flip y and z.
                let xc = (Float(u) - cx) * d / fx
                let yc = (Float(v) - cy) * d / fy
                let pCam = SIMD4<Float>(xc, -yc, -d, 1)
                let pWorld = camToWorld * pCam

                // Sample matching RGB pixel.
                let ru = Int(Float(u) / scaleX)
                let rv = Int(Float(v) / scaleY)
                if ru < 0 || ru >= rgbW || rv < 0 || rv >= rgbH { continue }
                let bi = (rv * rgbW + ru) * 4
                let r = rgbBytes[bi + 0]
                let g = rgbBytes[bi + 1]
                let b = rgbBytes[bi + 2]

                positions.append(SIMD3<Float>(pWorld.x, pWorld.y, pWorld.z))
                colors.append(SIMD3<UInt8>(r, g, b))
            }
        }
    }
}
