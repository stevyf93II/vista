//
//  TSDFPipeline.swift
//  Vista
//
//  Phase 2 orchestrator: read the per-frame disk dump, build a TSDF volume,
//  extract a triangle mesh via marching cubes, write a binary PLY.
//
//  Wired into the post-scan Task in RoomCaptureView alongside the existing
//  USDZ + naive_cloud.ply outputs. tsdf_mesh.ply is a developer artifact
//  (not surfaced in the Library yet). To inspect: pull from the device
//  container and open in MeshLab.
//

import Foundation
import UIKit
import CoreGraphics
import simd

enum TSDFPipeline {

    struct Config {
        var gridDim: Int = 128           // voxel grid resolution (128^3 = 25 MB)
        var maxFrames: Int = 60          // subsample input frames
        var minVoxelSize: Float = 0.005  // 5 mm
        var maxVoxelSize: Float = 0.05   // 5 cm
        var depthBufferMeters: Float = 1.5  // padding around camera bounds
        var truncationMultiple: Float = 4   // truncation = N * voxelSize
    }

    /// Returns the output PLY URL on success.
    @discardableResult
    static func run(framesRoot: URL,
                    to outURL: URL,
                    config: Config = Config()) throws -> URL {

        let fm = FileManager.default
        let decoder = JSONDecoder()

        // 1. List frame folders.
        let allFolders = try fm.contentsOfDirectory(
            at: framesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !allFolders.isEmpty else {
            throw NSError(domain: "TSDFPipeline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No frames on disk"])
        }

        // 2. Stride-subsample to maxFrames (orbit coverage preservation).
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

        // 3. Load metas first to compute bounds.
        var metas: [FrameMeta] = []
        for folder in folders {
            let metaURL = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(FrameMeta.self, from: data) else {
                continue
            }
            metas.append(meta)
        }
        guard !metas.isEmpty else {
            throw NSError(domain: "TSDFPipeline", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No metas readable"])
        }

        // Camera positions = last column of cameraTransform (row-major).
        var minP = SIMD3<Float>(.infinity, .infinity, .infinity)
        var maxP = SIMD3<Float>(-.infinity, -.infinity, -.infinity)
        for m in metas {
            let t = m.cameraTransformRowMajor
            let p = SIMD3<Float>(t[0][3], t[1][3], t[2][3])
            minP = min(minP, p)
            maxP = max(maxP, p)
        }
        // Pad bounds by depthBufferMeters so the volume covers the surfaces
        // the camera could see, not just the camera path itself.
        minP -= SIMD3<Float>(repeating: config.depthBufferMeters)
        maxP += SIMD3<Float>(repeating: config.depthBufferMeters)

        let extent = maxP - minP
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        var voxelSize = maxExtent / Float(config.gridDim)
        if voxelSize < config.minVoxelSize { voxelSize = config.minVoxelSize }
        if voxelSize > config.maxVoxelSize { voxelSize = config.maxVoxelSize }

        // Re-center the volume on the bounding box midpoint so the chosen
        // voxelSize covers the bounds even after clamping.
        let center = (minP + maxP) * 0.5
        let half = Float(config.gridDim) * voxelSize * 0.5
        let origin = center - SIMD3<Float>(repeating: half)

        var volumeConfig = VolumeConfig()
        volumeConfig.voxelSize = voxelSize
        volumeConfig.truncation = voxelSize * config.truncationMultiple

        let volume = TSDFVolume(dim: config.gridDim, origin: origin, config: volumeConfig)

        // 4. Integrate each frame into the volume.
        for (folder, meta) in zip(folders, metas) {
            autoreleasepool {
                integrateOne(volume: volume, folder: folder, meta: meta)
            }
        }

        // 5. Marching cubes.
        let mesh = MarchingCubes.extract(from: volume)

        // 6. Write PLY.
        guard !mesh.triangles.isEmpty else {
            throw NSError(domain: "TSDFPipeline", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Marching cubes produced 0 triangles"])
        }
        try PLYBinaryExporter.writeMesh(
            positions: mesh.positions,
            colors: mesh.colors,
            triangles: mesh.triangles,
            to: outURL
        )
        return outURL
    }

    /// Read one frame's depth + confidence + rgb, integrate into the volume.
    private static func integrateOne(volume: TSDFVolume,
                                     folder: URL,
                                     meta: FrameMeta) {
        let depthURL = folder.appendingPathComponent("depth.bin")
        let confURL = folder.appendingPathComponent("conf.bin")
        let rgbURL = folder.appendingPathComponent("rgb.jpg")

        guard let depthData = try? Data(contentsOf: depthURL),
              let confData = try? Data(contentsOf: confURL),
              let rgbImg = UIImage(contentsOfFile: rgbURL.path)?.cgImage else {
            return
        }
        let dw = meta.depthWidth
        let dh = meta.depthHeight
        guard depthData.count == dw * dh * 4 else { return }
        guard confData.count == dw * dh else { return }

        // Rescale intrinsics to depth resolution.
        let scaleX = Float(dw) / Float(meta.imageWidth)
        let scaleY = Float(dh) / Float(meta.imageHeight)
        let fx = meta.intrinsicsRowMajor[0][0] * scaleX
        let fy = meta.intrinsicsRowMajor[1][1] * scaleY
        let cx = meta.intrinsicsRowMajor[0][2] * scaleX
        let cy = meta.intrinsicsRowMajor[1][2] * scaleY
        let depthIntrinsics = simd_float3x3(
            SIMD3<Float>(fx, 0, 0),
            SIMD3<Float>(0, fy, 0),
            SIMD3<Float>(cx, cy, 1)
        )

        let m = meta.cameraTransformRowMajor
        let camToWorld = simd_float4x4(rows: [
            SIMD4<Float>(m[0][0], m[0][1], m[0][2], m[0][3]),
            SIMD4<Float>(m[1][0], m[1][1], m[1][2], m[1][3]),
            SIMD4<Float>(m[2][0], m[2][1], m[2][2], m[2][3]),
            SIMD4<Float>(m[3][0], m[3][1], m[3][2], m[3][3]),
        ])

        // Rasterize RGB to RGBA8.
        let rw = rgbImg.width
        let rh = rgbImg.height
        guard let ctx = CGContext(
            data: nil, width: rw, height: rh,
            bitsPerComponent: 8, bytesPerRow: rw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return }
        ctx.draw(rgbImg, in: CGRect(x: 0, y: 0, width: rw, height: rh))
        guard let rgbBase = ctx.data else { return }
        let rgbPtr = rgbBase.bindMemory(to: UInt8.self, capacity: rw * rh * 4)

        depthData.withUnsafeBytes { rawDepth in
            let depthPtr = rawDepth.bindMemory(to: Float.self).baseAddress!
            confData.withUnsafeBytes { rawConf in
                let confPtr = rawConf.bindMemory(to: UInt8.self).baseAddress!
                volume.integrate(
                    depth: depthPtr,
                    confidence: confPtr,
                    depthWidth: dw, depthHeight: dh,
                    rgb: rgbPtr, rgbWidth: rw, rgbHeight: rh,
                    depthIntrinsics: depthIntrinsics,
                    camToWorld: camToWorld
                )
            }
        }
    }
}
