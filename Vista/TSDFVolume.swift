//
//  TSDFVolume.swift
//  Vista
//
//  TSDF Phase 2: CPU fixed-grid TSDF integration.
//  Per Build Spec §5 + §11.2.
//
//  Each voxel stores a running weighted average of the truncated signed
//  distance to the nearest surface, plus a confidence weight and a
//  running-averaged RGB color. Overlapping observations of the same surface
//  from many frames AVERAGE into one clean value rather than stacking into
//  doubled point layers. That's the entire architectural difference between
//  this and the NaiveCloudExporter baseline.
//
//  Phase 4 ports the integrate kernel to Metal compute. Phase 2 is pure
//  Swift CPU -- expect 30-90 sec per scan on iPhone 12 Pro.
//

import Foundation
import simd

struct VolumeConfig {
    var voxelSize: Float = 0.015           // 15mm default per spec
    var truncation: Float = 0.06           // 4x voxelSize
    var maxWeight: Float = 64              // caps running average
    var minConfidence: UInt8 = 2           // .high only for v1
    var depthRange: ClosedRange<Float> = 0.3...4.5  // sensor reliability bounds
}

/// Per-frame integration counters. Diagnostic only — tells us WHY a scan
/// produced few/zero voxels (confidence starvation vs depth-range vs frustum).
struct IntegrateStats {
    var projected = 0            // voxels that projected into a valid depth pixel
    var conf0 = 0               // of those, pixels with ARKit confidence 0 (low)
    var conf1 = 0               // confidence 1 (medium)
    var conf2 = 0               // confidence 2 (high)
    var rejectedByConf = 0      // dropped: conf < minConfidence
    var rejectedByDepthRange = 0 // dropped: depth NaN or outside depthRange
    var rejectedBySDF = 0       // dropped: behind surface beyond -truncation
    var voxelUpdates = 0        // voxels actually written

    static func + (a: IntegrateStats, b: IntegrateStats) -> IntegrateStats {
        IntegrateStats(
            projected: a.projected + b.projected,
            conf0: a.conf0 + b.conf0,
            conf1: a.conf1 + b.conf1,
            conf2: a.conf2 + b.conf2,
            rejectedByConf: a.rejectedByConf + b.rejectedByConf,
            rejectedByDepthRange: a.rejectedByDepthRange + b.rejectedByDepthRange,
            rejectedBySDF: a.rejectedBySDF + b.rejectedBySDF,
            voxelUpdates: a.voxelUpdates + b.voxelUpdates
        )
    }
}

/// One voxel. 16 bytes packed.
struct Voxel {
    var tsdf: Float = 0
    var weight: Float = 0
    var color: SIMD3<UInt8> = SIMD3<UInt8>(0, 0, 0)
    var pad: UInt8 = 0
}

final class TSDFVolume {
    let dim: Int                    // grid resolution (128^3 for Phase 2)
    let origin: SIMD3<Float>        // world position of voxel (0,0,0) CORNER
    let voxelSize: Float
    let truncation: Float
    let maxWeight: Float
    let minConfidence: UInt8
    let depthRange: ClosedRange<Float>

    var voxels: [Voxel]

    init(dim: Int, origin: SIMD3<Float>, config: VolumeConfig) {
        self.dim = dim
        self.origin = origin
        self.voxelSize = config.voxelSize
        self.truncation = config.truncation
        self.maxWeight = config.maxWeight
        self.minConfidence = config.minConfidence
        self.depthRange = config.depthRange
        self.voxels = [Voxel](repeating: Voxel(), count: dim * dim * dim)
    }

    @inline(__always)
    func index(_ x: Int, _ y: Int, _ z: Int) -> Int {
        return (z * dim + y) * dim + x
    }

    @inline(__always)
    func worldOfVoxel(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
        return SIMD3<Float>(
            origin.x + (Float(x) + 0.5) * voxelSize,
            origin.y + (Float(y) + 0.5) * voxelSize,
            origin.z + (Float(z) + 0.5) * voxelSize
        )
    }

    /// Integrate one frame's depth + RGB + pose into the volume.
    ///
    /// Coordinate convention (verified against NaiveCloudExporter):
    ///   ARKit camera frame: +X right, +Y up, -Z forward.
    ///   Image pixel (u, v): u right, v down.
    ///   Unproject (u, v, d) -> ((u-cx)*d/fx, -(v-cy)*d/fy, -d) in cam.
    ///   Inverse projection then is:
    ///     u = pCam.x/(-pCam.z) * fx + cx
    ///     v = -pCam.y/(-pCam.z) * fy + cy
    ///
    /// depth/confidence dims expected: depthWidth x depthHeight (256x192).
    /// depthIntrinsics MUST already be rescaled to depth resolution.
    ///
    /// Returns per-frame diagnostic counters (discardable).
    @discardableResult
    func integrate(
        depth: UnsafePointer<Float>,
        confidence: UnsafePointer<UInt8>,
        depthWidth: Int,
        depthHeight: Int,
        rgb: UnsafePointer<UInt8>,
        rgbWidth: Int,
        rgbHeight: Int,
        depthIntrinsics: simd_float3x3,
        camToWorld: simd_float4x4
    ) -> IntegrateStats {
        let worldToCam = simd_inverse(camToWorld)

        // simd_float3x3 indexes as matrix[col][row].
        let fx = depthIntrinsics[0][0]
        let fy = depthIntrinsics[1][1]
        let cx = depthIntrinsics[2][0]
        let cy = depthIntrinsics[2][1]

        let depthMin = depthRange.lowerBound
        let depthMax = depthRange.upperBound

        // RGB pixel sampling needs depth-pixel -> rgb-pixel scale.
        let rgbScaleU = Float(rgbWidth) / Float(depthWidth)
        let rgbScaleV = Float(rgbHeight) / Float(depthHeight)

        // Pre-extract worldToCam rows for hot-loop scalar math.
        let m00 = worldToCam[0][0]; let m10 = worldToCam[1][0]; let m20 = worldToCam[2][0]; let m30 = worldToCam[3][0]
        let m01 = worldToCam[0][1]; let m11 = worldToCam[1][1]; let m21 = worldToCam[2][1]; let m31 = worldToCam[3][1]
        let m02 = worldToCam[0][2]; let m12 = worldToCam[1][2]; let m22 = worldToCam[2][2]; let m32 = worldToCam[3][2]

        // Diagnostic counters (see IntegrateStats).
        var nProjected = 0
        var nConf0 = 0, nConf1 = 0, nConf2 = 0
        var nRejConf = 0, nRejDepth = 0, nRejSDF = 0, nUpdates = 0

        // We hold voxels [Voxel] but mutate in place via index. Swift's CoW
        // makes [Voxel] effectively a contiguous buffer here since we never
        // hand out a copy.
        voxels.withUnsafeMutableBufferPointer { vbuf in
            let oX = origin.x, oY = origin.y, oZ = origin.z
            let vs = voxelSize
            for z in 0..<dim {
                let pwZ = oZ + (Float(z) + 0.5) * vs
                for y in 0..<dim {
                    let pwY = oY + (Float(y) + 0.5) * vs
                    for x in 0..<dim {
                        let pwX = oX + (Float(x) + 0.5) * vs

                        // worldToCam * (pwX, pwY, pwZ, 1) -> pCam
                        let pcX = m00 * pwX + m10 * pwY + m20 * pwZ + m30
                        let pcY = m01 * pwX + m11 * pwY + m21 * pwZ + m31
                        let pcZ = m02 * pwX + m12 * pwY + m22 * pwZ + m32

                        // ARKit looks -Z; visible points have negative z.
                        if pcZ >= 0 { continue }
                        let dRay = -pcZ

                        // Project to pixel.
                        let u = (pcX / dRay) * fx + cx
                        let v = -(pcY / dRay) * fy + cy
                        let ui = Int(u + 0.5)
                        let vi = Int(v + 0.5)
                        if ui < 0 || ui >= depthWidth || vi < 0 || vi >= depthHeight {
                            continue
                        }

                        let pIdx = vi * depthWidth + ui
                        let conf = confidence[pIdx]

                        // --- diagnostics: this voxel projected into the frame ---
                        nProjected += 1
                        if conf == 0 { nConf0 += 1 }
                        else if conf == 1 { nConf1 += 1 }
                        else { nConf2 += 1 }

                        if conf < minConfidence { nRejConf += 1; continue }
                        let dMeas = depth[pIdx]
                        if !dMeas.isFinite || dMeas < depthMin || dMeas > depthMax {
                            nRejDepth += 1
                            continue
                        }

                        // Signed distance along the ray, then truncate + normalize.
                        let sdf = dMeas - dRay
                        if sdf < -truncation { nRejSDF += 1; continue }
                        var tsdfNew = sdf / truncation
                        if tsdfNew > 1  { tsdfNew = 1 }
                        if tsdfNew < -1 { tsdfNew = -1 }

                        // Sample RGB at the projected depth pixel.
                        let ru = min(rgbWidth - 1, max(0, Int(u * rgbScaleU)))
                        let rv = min(rgbHeight - 1, max(0, Int(v * rgbScaleV)))
                        let bi = (rv * rgbWidth + ru) * 4
                        let r8 = rgb[bi + 0]
                        let g8 = rgb[bi + 1]
                        let b8 = rgb[bi + 2]

                        let w = Float(conf)
                        let vIdx = (z * dim + y) * dim + x
                        var vox = vbuf[vIdx]

                        // True running average: divide by the UNCAPPED weight
                        // sum, then cap the stored weight (standard
                        // KinectFusion update). Dividing by the capped weight
                        // makes tsdf drift past +/-1 once the cap is reached.
                        // Ported from swift-tsdf fix aea9de2.
                        let wSum = vox.weight + w

                        vox.tsdf = (vox.tsdf * vox.weight + tsdfNew * w) / wSum

                        // Running-average color, same denominator.
                        let rNew = (Float(vox.color.x) * vox.weight + Float(r8) * w) / wSum
                        let gNew = (Float(vox.color.y) * vox.weight + Float(g8) * w) / wSum
                        let bNew = (Float(vox.color.z) * vox.weight + Float(b8) * w) / wSum
                        vox.color = SIMD3<UInt8>(
                            UInt8(min(255, max(0, rNew))),
                            UInt8(min(255, max(0, gNew))),
                            UInt8(min(255, max(0, bNew)))
                        )
                        vox.weight = wSum > maxWeight ? maxWeight : wSum

                        vbuf[vIdx] = vox
                        nUpdates += 1
                    }
                }
            }
        }

        return IntegrateStats(
            projected: nProjected,
            conf0: nConf0, conf1: nConf1, conf2: nConf2,
            rejectedByConf: nRejConf,
            rejectedByDepthRange: nRejDepth,
            rejectedBySDF: nRejSDF,
            voxelUpdates: nUpdates
        )
    }
}
