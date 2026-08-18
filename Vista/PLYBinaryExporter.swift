//
//  PLYBinaryExporter.swift
//  Vista
//
//  Binary little-endian PLY writer. Phase 1 use: naive accumulated cloud.
//  Phase 2+ use: triangle mesh from marching cubes.
//
//  Per the build spec: positions(float32×3) + color(uchar×3) = 15 bytes/vertex.
//  Binary PLY is 3-5x smaller than ASCII at no quality cost. Always use binary.
//

import Foundation
import simd

enum PLYBinaryExporter {

    /// Write an unstructured point cloud (positions + per-vertex color) as
    /// binary little-endian PLY.
    static func writePointCloud(
        positions: [SIMD3<Float>],
        colors: [SIMD3<UInt8>],
        to url: URL
    ) throws {
        precondition(positions.count == colors.count, "positions/colors count mismatch")
        let n = positions.count

        let header = """
        ply
        format binary_little_endian 1.0
        comment Vista Phase 1 naive cloud
        element vertex \(n)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + n * 15)

        // Stream vertices: 12 bytes position + 3 bytes color = 15 bytes.
        positions.withUnsafeBufferPointer { posBuf in
            colors.withUnsafeBufferPointer { colBuf in
                for i in 0..<n {
                    var p = posBuf[i]
                    let c = colBuf[i]
                    withUnsafeBytes(of: &p.x) { data.append(contentsOf: $0) }
                    withUnsafeBytes(of: &p.y) { data.append(contentsOf: $0) }
                    withUnsafeBytes(of: &p.z) { data.append(contentsOf: $0) }
                    data.append(c.x)
                    data.append(c.y)
                    data.append(c.z)
                }
            }
        }
        try data.write(to: url)
    }

    /// Write a triangle mesh (positions + per-vertex color + triangles) as
    /// binary little-endian PLY. Reserved for Phase 2+ marching-cubes output.
    static func writeMesh(
        positions: [SIMD3<Float>],
        colors: [SIMD3<UInt8>],
        triangles: [(Int32, Int32, Int32)],
        to url: URL
    ) throws {
        precondition(positions.count == colors.count)
        let nv = positions.count
        let nf = triangles.count

        let header = """
        ply
        format binary_little_endian 1.0
        comment Vista Phase 2+ TSDF mesh
        element vertex \(nv)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(nf)
        property list uchar int vertex_indices
        end_header

        """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + nv * 15 + nf * 13)

        for i in 0..<nv {
            var p = positions[i]
            let c = colors[i]
            withUnsafeBytes(of: &p.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &p.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &p.z) { data.append(contentsOf: $0) }
            data.append(c.x); data.append(c.y); data.append(c.z)
        }
        for tri in triangles {
            data.append(3 as UInt8)
            var a = tri.0, b = tri.1, c = tri.2
            withUnsafeBytes(of: &a) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }
}
