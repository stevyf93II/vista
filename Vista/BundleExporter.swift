//
//  BundleExporter.swift
//  Vista
//
//  Phase 5.0 prep — materialize a self-contained, bake-ready bundle to
//  Documents/vista_bundles/<scan_name>/ at the end of a Room scan.
//
//  Layout (matches what vista-cloud/bake_pipeline.py reads):
//
//    Documents/vista_bundles/<scan_name>/
//      mesh.ply         - TSDF-fused mesh (or ARMeshAnchor fallback)
//      manifest.json    - frames[] (RGB+pose, all) + depth_frames[] (subsampled)
//      tsdf_debug.json  - per-scan TSDF diagnostics (if produced)
//      frames/
//        frame_<idx>.jpg  - per-frame RGB (1920x1440 from ARFrame.capturedImage)
//        depth_<idx>.bin  - 256x192 Float32 LE meters (subsampled set only)
//        conf_<idx>.bin   - 256x192 UInt8 ARKit confidence (subsampled set only)
//
//  RGB frames are exported for every captured frame (texture bake uses them).
//  Depth+conf are exported for a STRIDE-SUBSAMPLED ~300 frames only — that's
//  ample coverage for cloud TSDF fusion and keeps bundle growth ~70MB instead
//  of ~215MB for all ~900. The cloud rebuild reads depth_frames[] and fuses
//  with Open3D ScalableTSDFVolume at fine voxel size (no phone memory cap).
//
//  DISK HARDENING (2026-06-10): sources are MOVED into the bundle, not
//  copied — a same-volume move is a rename (zero extra bytes), halving the
//  scan's peak disk footprint. Safe because the Phase-1 USDZ build consumes
//  the tmp rgb.jpgs BEFORE exportBundle runs, and nothing reads the tmp
//  mesh/depth/conf afterwards. Falls back to copy per-file if a move fails.
//  A free-space precheck throws BundleExportError.lowDiskSpace instead of
//  letting iOS kill the app mid-write (bug_type 145, ~1 GB/session).
//
//  STORAGE LIFECYCLE (2026-06-10b): bundles used to accumulate forever
//  (~722 MB per scan -> 15+ GB app). Now: pruneOldBundles(keepLatest: 1)
//  runs before each export, and BakeUploader deletes the bundle once its
//  bake succeeds. Worst case on disk: the bundle of the current scan plus
//  one predecessor, transiently.
//
//  Intrinsics in manifest.json correspond to the FULL captured image
//  resolution; the cloud rescales them to 256x192 before unprojecting depth
//  (same as the on-device TSDF).
//
//  Requires UIFileSharingEnabled = YES in the target's Info plist for
//  iMazing / Apple Devices / Finder to expose Documents/.
//

import Foundation
import simd

enum BundleExportError: LocalizedError {
    case lowDiskSpace(freeMB: Int)

    var errorDescription: String? {
        switch self {
        case .lowDiskSpace(let freeMB):
            return "Not enough free storage to export the scan bundle " +
                   "(\(freeMB) MB free, need ~400 MB). Free up space and rescan."
        }
    }
}

enum BundleExporter {

    /// Number of frames to export depth+conf for (stride-subsampled).
    static let targetDepthFrames = 300

    /// Minimum free bytes required before attempting an export.
    static let minFreeBytes: Int64 = 400_000_000

    /// Move src -> dst; fall back to copy if the move fails (cross-volume,
    /// file still open, etc.). Replaces dst if present.
    private static func moveOrCopy(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        do {
            try fm.moveItem(at: src, to: dst)
        } catch {
            try fm.copyItem(at: src, to: dst)
        }
    }

    /// Delete all but the `keepLatest` newest bundle dirs (by modification
    /// date). Bundles are single-purpose upload payloads — once baked (or
    /// superseded by a newer scan) they are dead weight at ~722 MB each.
    static func pruneOldBundles(keepLatest: Int = 1) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("vista_bundles", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return }
        let dirs = items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return da > db   // newest first
            }
        guard dirs.count > keepLatest else { return }
        for old in dirs.dropFirst(keepLatest) {
            try? fm.removeItem(at: old)
        }
    }

    /// Delete one bundle dir (called by BakeUploader after a successful bake).
    static func deleteBundle(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    static func exportBundle(
        scanName: String,
        meshURL: URL,
        framesRoot: URL
    ) throws -> URL {
        let fm = FileManager.default

        // Documents/vista_bundles/<scan_name>/
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Reclaim space from previous scans BEFORE the free-space check —
        // old bundles are the main thing eating the disk.
        pruneOldBundles(keepLatest: 1)

        // Free-space precheck — fail loud and early, not mid-write.
        if let vals = try? docs.resourceValues(
               forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = vals.volumeAvailableCapacityForImportantUsage,
           free < minFreeBytes {
            throw BundleExportError.lowDiskSpace(freeMB: Int(free / 1_000_000))
        }

        let bundlesRoot = docs.appendingPathComponent("vista_bundles", isDirectory: true)
        let bundleRoot = bundlesRoot.appendingPathComponent(scanName, isDirectory: true)
        let bundleFramesRoot = bundleRoot.appendingPathComponent("frames", isDirectory: true)

        try fm.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleFramesRoot, withIntermediateDirectories: true)

        // 1. Move mesh.ply into the bundle (nothing reads the tmp copy after).
        let destMesh = bundleRoot.appendingPathComponent("mesh.ply")
        try moveOrCopy(meshURL, to: destMesh)

        // 2. Walk frames/, move each rgb.jpg + collect meta. Remember which
        //    folders have usable depth so we can subsample them in step 3.
        let decoder = JSONDecoder()
        var manifestFrames: [ManifestFrame] = []
        var depthCandidates: [(idx: String, folder: URL, meta: FrameMeta)] = []

        let folders = try fm.contentsOfDirectory(
            at: framesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for folder in folders {
            let idx = folder.lastPathComponent   // e.g. "00000"
            let metaURL = folder.appendingPathComponent("meta.json")
            let rgbURL = folder.appendingPathComponent("rgb.jpg")

            guard let metaData = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(FrameMeta.self, from: metaData),
                  fm.fileExists(atPath: rgbURL.path) else {
                continue
            }

            let destRGB = bundleFramesRoot.appendingPathComponent("frame_\(idx).jpg")
            try moveOrCopy(rgbURL, to: destRGB)

            manifestFrames.append(ManifestFrame(
                file: "frames/frame_\(idx).jpg",
                intrinsics_3x3: meta.intrinsicsRowMajor,
                camera_to_world_4x4: meta.cameraTransformRowMajor
            ))

            // Eligible for depth export only if depth+conf actually exist.
            let depthURL = folder.appendingPathComponent("depth.bin")
            let confURL = folder.appendingPathComponent("conf.bin")
            if fm.fileExists(atPath: depthURL.path),
               fm.fileExists(atPath: confURL.path) {
                depthCandidates.append((idx: idx, folder: folder, meta: meta))
            }
        }

        // 3. Stride-subsample depth candidates to ~targetDepthFrames, move
        //    depth+conf, and build depth_frames[] for the cloud rebuild.
        var depthFrames: [DepthFrame] = []
        let n = depthCandidates.count
        if n > 0 {
            let stride = max(1, n / targetDepthFrames)
            var i = 0
            while i < n && depthFrames.count < targetDepthFrames {
                let cand = depthCandidates[i]
                let srcDepth = cand.folder.appendingPathComponent("depth.bin")
                let srcConf = cand.folder.appendingPathComponent("conf.bin")
                let dstDepth = bundleFramesRoot.appendingPathComponent("depth_\(cand.idx).bin")
                let dstConf = bundleFramesRoot.appendingPathComponent("conf_\(cand.idx).bin")
                do {
                    try moveOrCopy(srcDepth, to: dstDepth)
                    try moveOrCopy(srcConf, to: dstConf)
                    depthFrames.append(DepthFrame(
                        depth_file: "frames/depth_\(cand.idx).bin",
                        conf_file: "frames/conf_\(cand.idx).bin",
                        rgb_file: "frames/frame_\(cand.idx).jpg",
                        intrinsics_3x3: cand.meta.intrinsicsRowMajor,
                        camera_to_world_4x4: cand.meta.cameraTransformRowMajor,
                        image_width: cand.meta.imageWidth,
                        image_height: cand.meta.imageHeight,
                        depth_width: cand.meta.depthWidth,
                        depth_height: cand.meta.depthHeight,
                        tracking_state: cand.meta.trackingState
                    ))
                } catch {
                    // skip this frame's depth on move failure; non-fatal
                }
                i += stride
            }
        }

        // 4. Write manifest.json (RGB frames + subsampled depth frames).
        let manifest = Manifest(frames: manifestFrames, depth_frames: depthFrames)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: bundleRoot.appendingPathComponent("manifest.json"))

        // 5. Copy TSDF diagnostics (written by computeMesh next to frames/) into
        //    the bundle so we can read why a scan failed without a USB console.
        let debugSrc = framesRoot.deletingLastPathComponent()
            .appendingPathComponent("tsdf_debug.json")
        if fm.fileExists(atPath: debugSrc.path) {
            let debugDst = bundleRoot.appendingPathComponent("tsdf_debug.json")
            if fm.fileExists(atPath: debugDst.path) { try? fm.removeItem(at: debugDst) }
            try? fm.copyItem(at: debugSrc, to: debugDst)
        }

        return bundleRoot
    }

    /// Disk size of a bundle (best-effort).
    static func sizeBytes(of bundleRoot: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumr = fm.enumerator(at: bundleRoot,
                                        includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumr {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                total += Int64(size)
            }
        }
        return total
    }

    /// Newest bundle directory under Documents/vista_bundles/, by modification
    /// date. Used by the cloud-bake action to find the just-finished scan's
    /// bundle without threading the path through the capture/export closures.
    /// The capture UI is strictly one-scan-at-a-time, so "newest" is the scan
    /// the user just completed.
    static func latestBundleDir() -> URL? {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("vista_bundles", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return nil }

        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return da < db
            }
    }
}

// MARK: - manifest schema (matches bake_pipeline.py)

private struct Manifest: Codable {
    let frames: [ManifestFrame]
    let depth_frames: [DepthFrame]
}

private struct ManifestFrame: Codable {
    let file: String
    let intrinsics_3x3: [[Float]]
    let camera_to_world_4x4: [[Float]]
}

// Per-depth-frame record for the cloud TSDF rebuild. depth.bin is
// depth_width*depth_height Float32 little-endian meters; conf.bin is the same
// dims UInt8 (ARKit confidence 0/1/2). intrinsics are for image_width/height
// and must be rescaled to depth dims before unprojecting.
private struct DepthFrame: Codable {
    let depth_file: String
    let conf_file: String
    let rgb_file: String
    let intrinsics_3x3: [[Float]]
    let camera_to_world_4x4: [[Float]]
    let image_width: Int
    let image_height: Int
    let depth_width: Int
    let depth_height: Int
    let tracking_state: String?
}
