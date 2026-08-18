//
//  TSDFPipeline+Extras.swift
//  Vista
//
//  Phase 5 bridge: exposes `computeMesh` (returns the TSDF mesh in memory)
//  and `buildUSDZ` (writes a USDZ from a raw triangle mesh via SceneKit) so
//  RoomCaptureView can share one TSDF pass across PLY + USDZ outputs.
//
//  Implementation note on `computeMesh`: duplicates the body of
//  TSDFPipeline.run() up to the MarchingCubes.extract step, then returns
//  the mesh. Kept here rather than refactoring run() so the Phase 2 file
//  stays bit-identical to the commit it was restored from.
//
//  2026-06-08 instrumentation: computeMesh now writes `tsdf_debug.json` next
//  to the frames folder (sessionRoot) recording frame/voxel/triangle counts
//  and a confidence histogram, so a failed (0-triangle) scan tells us WHY
//  without needing a USB device console. BundleExporter copies it into the
//  bake bundle.
//

import Foundation
import SceneKit
import UIKit
import simd

/// Per-frame on-disk + integration outcome (diagnostic only).
struct FrameStat {
    var depthPresent = false
    var confPresent = false
    var dimOK = false
    var integrate = IntegrateStats()
}

/// Serialized to tsdf_debug.json. One per scan.
struct TSDFDebug: Codable {
    var folders: Int
    var metasRead: Int
    var framesDepthPresent: Int
    var framesConfPresent: Int
    var framesDimOK: Int
    var totalProjected: Int
    var conf0: Int
    var conf1: Int
    var conf2: Int
    var rejectedByConf: Int
    var rejectedByDepthRange: Int
    var rejectedBySDF: Int
    var voxelUpdates: Int
    var observedVoxels: Int
    var triangleCount: Int
    var gridDim: Int
    var voxelSize: Float
    var truncation: Float
    var minConfidence: Int
    var boundsMin: [Float]
    var boundsMax: [Float]
}

extension TSDFPipeline {

    /// Run the TSDF integration + marching cubes and return the mesh in memory.
    static func computeMesh(framesRoot: URL,
                            config: Config = Config()) throws -> MarchingCubes.Mesh {
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

        // 2. Stride-subsample to maxFrames.
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
        minP -= SIMD3<Float>(repeating: config.depthBufferMeters)
        maxP += SIMD3<Float>(repeating: config.depthBufferMeters)
        let extent = maxP - minP
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        var voxelSize = maxExtent / Float(config.gridDim)
        if voxelSize < config.minVoxelSize { voxelSize = config.minVoxelSize }
        if voxelSize > config.maxVoxelSize { voxelSize = config.maxVoxelSize }
        let center = (minP + maxP) * 0.5
        let half = Float(config.gridDim) * voxelSize * 0.5
        let origin = center - SIMD3<Float>(repeating: half)

        var volumeConfig = VolumeConfig()
        volumeConfig.voxelSize = voxelSize
        volumeConfig.truncation = voxelSize * config.truncationMultiple
        let volume = TSDFVolume(dim: config.gridDim, origin: origin, config: volumeConfig)

        // 4. Integrate each frame, aggregating diagnostics.
        var agg = IntegrateStats()
        var framesDepthPresent = 0
        var framesConfPresent = 0
        var framesDimOK = 0
        for (folder, meta) in zip(folders, metas) {
            var fs = FrameStat()
            autoreleasepool {
                fs = Self.integrateOneBridge(volume: volume, folder: folder, meta: meta)
            }
            if fs.depthPresent { framesDepthPresent += 1 }
            if fs.confPresent { framesConfPresent += 1 }
            if fs.dimOK { framesDimOK += 1 }
            agg = agg + fs.integrate
        }

        // 5. Marching cubes.
        let mesh = MarchingCubes.extract(from: volume)

        // 6. Write diagnostics next to the frames folder (sessionRoot).
        let observed = volume.voxels.reduce(0) { $0 + ($1.weight > 0 ? 1 : 0) }
        let debug = TSDFDebug(
            folders: allFolders.count,
            metasRead: metas.count,
            framesDepthPresent: framesDepthPresent,
            framesConfPresent: framesConfPresent,
            framesDimOK: framesDimOK,
            totalProjected: agg.projected,
            conf0: agg.conf0, conf1: agg.conf1, conf2: agg.conf2,
            rejectedByConf: agg.rejectedByConf,
            rejectedByDepthRange: agg.rejectedByDepthRange,
            rejectedBySDF: agg.rejectedBySDF,
            voxelUpdates: agg.voxelUpdates,
            observedVoxels: observed,
            triangleCount: mesh.triangles.count,
            gridDim: config.gridDim,
            voxelSize: voxelSize,
            truncation: volumeConfig.truncation,
            minConfidence: Int(volumeConfig.minConfidence),
            boundsMin: [minP.x, minP.y, minP.z],
            boundsMax: [maxP.x, maxP.y, maxP.z]
        )
        let sessionRoot = framesRoot.deletingLastPathComponent()
        let debugURL = sessionRoot.appendingPathComponent("tsdf_debug.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(debug) {
            try? data.write(to: debugURL)
        }
        NSLog("[TSDF] debug: frames=\(allFolders.count) dimOK=\(framesDimOK) projected=\(agg.projected) conf0/1/2=\(agg.conf0)/\(agg.conf1)/\(agg.conf2) rejConf=\(agg.rejectedByConf) rejDepth=\(agg.rejectedByDepthRange) updates=\(agg.voxelUpdates) observedVoxels=\(observed) tris=\(mesh.triangles.count)")

        return mesh
    }

    /// Read one frame's depth + conf + rgb and integrate it; report what happened.
    private static func integrateOneBridge(volume: TSDFVolume, folder: URL, meta: FrameMeta) -> FrameStat {
        var stat = FrameStat()

        let depthURL = folder.appendingPathComponent("depth.bin")
        let confURL  = folder.appendingPathComponent("conf.bin")
        let rgbURL   = folder.appendingPathComponent("rgb.jpg")

        let depthData = try? Data(contentsOf: depthURL)
        let confData  = try? Data(contentsOf: confURL)
        let rgbImg    = UIImage(contentsOfFile: rgbURL.path)?.cgImage

        stat.depthPresent = (depthData != nil)
        stat.confPresent  = (confData != nil)

        guard let depthData, let confData, let rgbImg else { return stat }

        let dw = meta.depthWidth
        let dh = meta.depthHeight
        guard depthData.count == dw * dh * 4 else { return stat }
        guard confData.count  == dw * dh else { return stat }
        stat.dimOK = true

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

        let rw = rgbImg.width
        let rh = rgbImg.height
        guard let ctx = CGContext(
            data: nil, width: rw, height: rh,
            bitsPerComponent: 8, bytesPerRow: rw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return stat }
        ctx.draw(rgbImg, in: CGRect(x: 0, y: 0, width: rw, height: rh))
        guard let rgbBase = ctx.data else { return stat }
        let rgbPtr = rgbBase.bindMemory(to: UInt8.self, capacity: rw * rh * 4)

        stat.integrate = depthData.withUnsafeBytes { rawDepth -> IntegrateStats in
            let depthPtr = rawDepth.bindMemory(to: Float.self).baseAddress!
            return confData.withUnsafeBytes { rawConf -> IntegrateStats in
                let confPtr = rawConf.bindMemory(to: UInt8.self).baseAddress!
                return volume.integrate(
                    depth: depthPtr,
                    confidence: confPtr,
                    depthWidth: dw, depthHeight: dh,
                    rgb: rgbPtr, rgbWidth: rw, rgbHeight: rh,
                    depthIntrinsics: depthIntrinsics,
                    camToWorld: camToWorld
                )
            }
        }
        return stat
    }

    /// Write a USDZ from a raw (positions / colors / triangles) mesh using SceneKit.
    static func buildUSDZ(mesh: MarchingCubes.Mesh, to outURL: URL) throws {
        guard !mesh.triangles.isEmpty else {
            throw NSError(domain: "TSDFPipeline", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Empty mesh, nothing to export"])
        }

        // Flatten positions to [Float] so SceneKit reads tightly packed xyz triplets
        // (SIMD3<Float> is 16-byte aligned and would confuse the stride calculation).
        var posFlat: [Float] = []
        posFlat.reserveCapacity(mesh.positions.count * 3)
        for p in mesh.positions {
            posFlat.append(p.x); posFlat.append(p.y); posFlat.append(p.z)
        }
        let posData = posFlat.withUnsafeBufferPointer { Data(buffer: $0) }
        let posSource = SCNGeometrySource(
            data: posData,
            semantic: .vertex,
            vectorCount: mesh.positions.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )

        // Per-vertex colors as UInt8 RGB triplets.
        var colFlat: [UInt8] = []
        colFlat.reserveCapacity(mesh.colors.count * 3)
        for c in mesh.colors {
            colFlat.append(c.x); colFlat.append(c.y); colFlat.append(c.z)
        }
        let colorData = colFlat.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: mesh.colors.count,
            usesFloatComponents: false,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<UInt8>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<UInt8>.size * 3
        )

        // Triangle indices.
        var indices: [Int32] = []
        indices.reserveCapacity(mesh.triangles.count * 3)
        for tri in mesh.triangles {
            indices.append(tri.0); indices.append(tri.1); indices.append(tri.2)
        }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: mesh.triangles.count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geometry = SCNGeometry(sources: [posSource, colorSource], elements: [element])

        // Matte / unlit-ish material so per-vertex colors come through cleanly.
        let material = SCNMaterial()
        material.lightingModel = .constant       // unlit — show baked color directly
        material.diffuse.contents = UIColor.white
        material.isDoubleSided = true
        material.locksAmbientWithDiffuse = true
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        let scene = SCNScene()
        scene.rootNode.addChildNode(node)

        let ok = scene.write(to: outURL, options: nil, delegate: nil, progressHandler: nil)
        if !ok {
            throw NSError(domain: "TSDFPipeline", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "SceneKit USDZ write returned false"])
        }
    }
}
