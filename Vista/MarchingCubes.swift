//
//  MarchingCubes.swift
//  Vista
//
//  Per Build Spec §6. Walk each cube of 8 neighboring voxels in the TSDF
//  volume, classify by sign pattern, interpolate vertex positions along
//  crossed edges using the TSDF magnitudes for sub-voxel accuracy, emit
//  triangles per the standard Lorensen-Cline table.
//
//  Output: unwelded vertices (3 per triangle). Phase 5 can add welding.
//  Skipping cubes where any corner has weight==0 keeps unobserved regions
//  out of the output.
//

import Foundation
import simd

enum MarchingCubes {

    struct Mesh {
        var positions: [SIMD3<Float>]
        var colors: [SIMD3<UInt8>]
        var triangles: [(Int32, Int32, Int32)]
    }

    static func extract(from volume: TSDFVolume) -> Mesh {
        let dim = volume.dim
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []
        var triangles: [(Int32, Int32, Int32)] = []

        // Estimated capacity. Typical marching cubes yields ~0.5-2 tris per
        // surface voxel; we just reserve a sane lower bound.
        positions.reserveCapacity(200_000)
        colors.reserveCapacity(200_000)
        triangles.reserveCapacity(70_000)

        for z in 0..<(dim - 1) {
            for y in 0..<(dim - 1) {
                for x in 0..<(dim - 1) {
                    // Gather the 8 corner voxels of this cube.
                    var corners = [Voxel](repeating: Voxel(), count: 8)
                    var anyUnobserved = false
                    for i in 0..<8 {
                        let (dx, dy, dz) = cornerOffsets[i]
                        let vox = volume.voxels[volume.index(x + dx, y + dy, z + dz)]
                        if vox.weight <= 0 { anyUnobserved = true; break }
                        corners[i] = vox
                    }
                    if anyUnobserved { continue }

                    // Build 8-bit case index: bit i set if corner i is INSIDE
                    // the surface (tsdf < 0).
                    var caseIdx = 0
                    for i in 0..<8 where corners[i].tsdf < 0 { caseIdx |= (1 << i) }
                    if caseIdx == 0 || caseIdx == 255 { continue }

                    let edgeMask = edgeTable[caseIdx]
                    if edgeMask == 0 { continue }

                    // Compute interpolated position + color for each crossed edge.
                    var edgeVerts = [SIMD3<Float>](repeating: .zero, count: 12)
                    var edgeCols  = [SIMD3<UInt8>](repeating: .zero, count: 12)
                    for e in 0..<12 {
                        if (edgeMask & UInt16(1 << e)) == 0 { continue }
                        let (a, b) = edgeVertexPairs[e]
                        let tA = corners[a].tsdf
                        let tB = corners[b].tsdf
                        let denom = tA - tB
                        let t: Float
                        if abs(denom) < 1e-6 { t = 0.5 }
                        else { t = tA / denom }

                        let (ax, ay, az) = cornerOffsets[a]
                        let (bx, by, bz) = cornerOffsets[b]
                        let pA = volume.worldOfVoxel(x + ax, y + ay, z + az)
                        let pB = volume.worldOfVoxel(x + bx, y + by, z + bz)
                        edgeVerts[e] = pA + (pB - pA) * t

                        let cA = SIMD3<Float>(Float(corners[a].color.x),
                                              Float(corners[a].color.y),
                                              Float(corners[a].color.z))
                        let cB = SIMD3<Float>(Float(corners[b].color.x),
                                              Float(corners[b].color.y),
                                              Float(corners[b].color.z))
                        let cI = cA + (cB - cA) * t
                        edgeCols[e] = SIMD3<UInt8>(
                            UInt8(min(255, max(0, cI.x))),
                            UInt8(min(255, max(0, cI.y))),
                            UInt8(min(255, max(0, cI.z)))
                        )
                    }

                    // Emit triangles. Each set of 3 edge IDs in triTable[caseIdx]
                    // is one triangle; terminated by -1.
                    let tri = triTable[caseIdx]
                    var i = 0
                    while i + 2 < tri.count && tri[i] >= 0 {
                        let e0 = Int(tri[i])
                        let e1 = Int(tri[i + 1])
                        let e2 = Int(tri[i + 2])
                        let baseIdx = Int32(positions.count)
                        positions.append(edgeVerts[e0])
                        positions.append(edgeVerts[e1])
                        positions.append(edgeVerts[e2])
                        colors.append(edgeCols[e0])
                        colors.append(edgeCols[e1])
                        colors.append(edgeCols[e2])
                        triangles.append((baseIdx, baseIdx + 1, baseIdx + 2))
                        i += 3
                    }
                }
            }
        }

        return Mesh(positions: positions, colors: colors, triangles: triangles)
    }
}
