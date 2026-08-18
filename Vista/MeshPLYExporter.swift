//
//  MeshPLYExporter.swift
//  Vista
//
//  Phase 5.0 prep — combine multiple ARMeshAnchor anchors into one
//  world-space binary PLY (positions + face indices only). This is the
//  geometry the cloud bake pipeline consumes as mesh.ply.
//
//  No colors or normals: bake_pipeline.py runs its own mesh cleanup +
//  normal compute downstream.
//

import Foundation
import ARKit
import simd

enum MeshPLYExporter {

    /// Combine multiple ARMeshAnchor meshes into one binary PLY at `url`.
    /// Vertices are transformed to world space using each anchor's transform.
    /// Face indices are offset per-anchor so the combined buffer references
    /// the global vertex list.
    static func exportArMeshAnchors(_ anchors: [ARMeshAnchor], to url: URL) throws {
        var positions: [SIMD3<Float>] = []
        var faces: [(UInt32, UInt32, UInt32)] = []

        // Rough capacity hint to limit reallocations on big rooms.
        positions.reserveCapacity(anchors.reduce(0) { $0 + $1.geometry.vertices.count })
        faces.reserveCapacity(anchors.reduce(0) { $0 + $1.geometry.faces.count })

        for anchor in anchors {
            let geo = anchor.geometry
            let transform = anchor.transform
            let vBase = geo.vertices.buffer.contents()
            let vOffset = geo.vertices.offset
            let vStride = geo.vertices.stride

            let vertexBaseIdx = UInt32(positions.count)

            for i in 0..<geo.vertices.count {
                let local = vBase.advanced(by: vOffset + i * vStride)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let worldH = transform * SIMD4<Float>(local, 1)
                positions.append(SIMD3<Float>(worldH.x, worldH.y, worldH.z))
            }

            let idxBase = geo.faces.buffer.contents()
            let bytesPerIndex = geo.faces.bytesPerIndex
            let primCount = geo.faces.indexCountPerPrimitive
            precondition(primCount == 3, "Expected triangles")

            for t in 0..<geo.faces.count {
                let a = readIndex(at: idxBase, tri: t, idx: 0, bytesPerIndex: bytesPerIndex)
                let b = readIndex(at: idxBase, tri: t, idx: 1, bytesPerIndex: bytesPerIndex)
                let c = readIndex(at: idxBase, tri: t, idx: 2, bytesPerIndex: bytesPerIndex)
                faces.append((
                    UInt32(a) + vertexBaseIdx,
                    UInt32(b) + vertexBaseIdx,
                    UInt32(c) + vertexBaseIdx
                ))
            }
        }

        try writeBinaryPLY(positions: positions, faces: faces, to: url)
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

    /// Binary little-endian PLY: positions(float32×3) + faces(uchar count + uint32×3).
    /// No colors / normals.
    private static func writeBinaryPLY(positions: [SIMD3<Float>],
                                       faces: [(UInt32, UInt32, UInt32)],
                                       to url: URL) throws {
        let nv = positions.count
        let nf = faces.count

        let header = """
        ply
        format binary_little_endian 1.0
        comment Vista ARMeshAnchor combined mesh
        element vertex \(nv)
        property float x
        property float y
        property float z
        element face \(nf)
        property list uchar uint vertex_indices
        end_header

        """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + nv * 12 + nf * 13)

        for i in 0..<nv {
            var p = positions[i]
            withUnsafeBytes(of: &p.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &p.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &p.z) { data.append(contentsOf: $0) }
        }
        for tri in faces {
            data.append(3 as UInt8)
            var a = tri.0, b = tri.1, c = tri.2
            withUnsafeBytes(of: &a) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }
}
