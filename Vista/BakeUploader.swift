//
//  BakeUploader.swift
//  Vista
//
//  Phase 6, roadmap #2 piece 2 — chunked bundle uploader (phone -> Modal Volume).
//
//  The single 800 MB POST to the Modal `submit` endpoint is dead: Modal caps the
//  web request body and resets the connection. Instead we zip the bake-ready
//  bundle (Documents/vista_bundles/<scan_name>/), split it into ~10 MB chunks,
//  and POST them SEQUENTIALLY to the volume-mounted `upload_chunk` endpoint.
//  `finish_upload` concatenates the parts on the Volume into <id>.zip and spawns
//  the bake; we then poll the `result` endpoint for the GLB.
//
//  All three endpoints are routes of one Modal asgi function (`upload_app`),
//  kept as a single web function to stay under Modal's 8-web-function cap.
//
//  Server contract (vista-cloud/vista_modal.py, upload_app + process_volume_web):
//    POST {uploadChunk}?id=<id>&index=<i>   body = raw chunk bytes  -> {"ok":true,...}
//    POST {finishUpload}?id=<id>&parts=<N>                          -> {"call_id":"..."}
//    GET  {result}?call_id=<call_id>   -> 202 while baking, 200 model/gltf-binary when done
//
//  `id` is a fresh UUID per upload. Chunks are posted in order; the client awaits
//  each response before sending the next (matches the server's sequential,
//  per-file Volume-commit assumption — no concurrent writes to the same upload).
//
//  Auth: every request sends `Authorization: Bearer <token>`. The token is
//  read from Settings (UserDefaults key vistaUploadToken, Advanced section)
//  and must match the `vista-token` secret on your bake server; wrong or
//  missing token -> 401. Cloud bake is optional — the on-device pipeline
//  works without any server.
//
//  STORAGE (2026-06-10b): on success the source bundle is DELETED — it has
//  served its purpose and each one is ~722 MB. Failures throw before the
//  delete, so 'Retry bake' still finds the bundle via latestBundleDir().
//

import Foundation

/// Uploads a bake bundle to the Modal worker in chunks and returns the baked GLB.
struct BakeUploader {

    // MARK: Endpoints

    struct Endpoints {
        var uploadChunk: URL
        var finishUpload: URL
        var result: URL
        var usdz: URL

        /// Placeholder endpoints. All three are routes of a single asgi web
        /// function (`<your-workspace>--vista-cloud-upload-app.modal.run`) — kept
        /// as one web function to stay under Modal's 8-web-function workspace
        /// cap. Set your deployment's base URL in Settings (Advanced ->
        /// "Bake server URL"); until then, cloud bake requests fail fast with a
        /// clear error while the on-device pipeline keeps working.
        static let modalDefault = Endpoints(
            uploadChunk: URL(string: "https://example.invalid/upload_chunk")!,
            finishUpload: URL(string: "https://example.invalid/finish_upload")!,
            result: URL(string: "https://example.invalid/result")!,
            usdz: URL(string: "https://example.invalid/usdz")!
        )

        /// Reads an override base URL from UserDefaults (Settings) if present, else
        /// uses `modalDefault`. Key: vistaUploadAppBaseURL (the asgi app base, no
        /// path) — all three routes are derived from it. vistaResultURL can still
        /// override just /result if it ever moves.
        static func fromSettings() -> Endpoints {
            var ep = modalDefault
            let d = UserDefaults.standard
            if let base = d.string(forKey: "vistaUploadAppBaseURL"),
               let u = URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base) {
                ep.uploadChunk = u.appendingPathComponent("upload_chunk")
                ep.finishUpload = u.appendingPathComponent("finish_upload")
                ep.result = u.appendingPathComponent("result")
                ep.usdz = u.appendingPathComponent("usdz")
            }
            if let res = d.string(forKey: "vistaResultURL"), let u = URL(string: res) {
                ep.result = u
            }
            return ep
        }
    }

    // MARK: Progress

    enum Stage {
        case zipping
        case uploading(sentBytes: Int64, totalBytes: Int64)
        case finishing
        case baking
        case downloading
    }

    // MARK: Errors

    enum BakeError: LocalizedError {
        case zipFailed(String)
        case chunkRejected(index: Int, status: Int, body: String)
        case finishFailed(status: Int, body: String)
        case noCallID
        case bakeServerError(status: Int, body: String)
        case timedOut(seconds: Int)

        var errorDescription: String? {
            switch self {
            case .zipFailed(let m):
                return "Could not zip bundle: \(m)"
            case .chunkRejected(let i, let s, let b):
                return "Chunk \(i) rejected (HTTP \(s)): \(b)"
            case .finishFailed(let s, let b):
                return "finish_upload failed (HTTP \(s)): \(b)"
            case .noCallID:
                return "finish_upload did not return a call_id"
            case .bakeServerError(let s, let b):
                return "Bake failed (HTTP \(s)): \(b)"
            case .timedOut(let s):
                return "Bake timed out after \(s)s"
            }
        }
    }

    // MARK: Config

    var endpoints: Endpoints = .fromSettings()
    var chunkSize: Int = 10 * 1024 * 1024          // 10 MB
    var pollInterval: TimeInterval = 4             // seconds between result polls
    var bakeTimeout: TimeInterval = 30 * 60        // 30 min ceiling

    /// Shared-secret bearer token, read from Settings (UserDefaults key
    /// vistaUploadToken — Advanced section). Matched by the `vista-token`
    /// secret on the bake server.
    var token: String {
        UserDefaults.standard.string(forKey: "vistaUploadToken") ?? ""
    }

    private func authorize(_ req: inout URLRequest) {
        let t = token
        if !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
    }

    private var session: URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300        // a slow 10 MB chunk still finishes
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }

    // MARK: Public API

    /// Zips `bundleDir`, uploads it in chunks, triggers the bake, polls until the
    /// GLB is ready, and saves it to Documents/vista_bakes/<bundleName>.glb.
    /// - Returns: local URL of the downloaded GLB.
    @discardableResult
    func uploadAndBake(
        bundleDir: URL,
        progress: @escaping (Stage) -> Void = { _ in }
    ) async throws -> URL {
        let urlSession = session

        // 1. Zip the bundle directory to a temp .zip.
        progress(.zipping)
        let zipURL = try Self.zipDirectory(bundleDir)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        // 2. Fresh upload id.
        let uploadID = UUID().uuidString.lowercased()   // 36 chars, [a-f0-9-] -> server regex OK

        // 3. Stream the zip in chunks, POST each sequentially.
        let totalBytes = Int64(
            (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? 0
        )
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }

        var index = 0
        var sent: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            try await postChunk(chunk, id: uploadID, index: index, session: urlSession)
            sent += Int64(chunk.count)
            index += 1
            progress(.uploading(sentBytes: sent, totalBytes: totalBytes))
        }
        let partCount = index

        // 4. Assemble + spawn the bake.
        progress(.finishing)
        let callID = try await finishUpload(id: uploadID, parts: partCount, session: urlSession)

        // 5. Poll result until the GLB is ready.
        progress(.baking)
        let glb = try await pollResult(callID: callID, session: urlSession, progress: progress)

        // 6. Persist the GLB next to the other scans.
        let dest = try Self.saveGLB(glb, named: bundleDir.lastPathComponent)

        // 6.5. AR-for-bakes: fetch the USDZ twin the worker rendered
        //      alongside the GLB. Best-effort — a missing twin only means
        //      no AR tile for this bake, never a failed bake.
        await downloadUSDZTwin(id: uploadID,
                               named: bundleDir.lastPathComponent,
                               session: urlSession)

        // 7. The bundle has served its purpose — reclaim ~722 MB. Any failure
        //    above throws before this line, so 'Retry bake' keeps its source.
        BundleExporter.deleteBundle(at: bundleDir)

        return dest
    }

    // MARK: Steps

    private func postChunk(_ data: Data, id: String, index: Int,
                           session: URLSession) async throws {
        var comps = URLComponents(url: endpoints.uploadChunk, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "index", value: String(index)),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        authorize(&req)

        let (respData, resp) = try await session.upload(for: req, from: data)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw BakeError.chunkRejected(
                index: index, status: status,
                body: String(data: respData, encoding: .utf8) ?? "")
        }
    }

    private func finishUpload(id: String, parts: Int,
                             session: URLSession) async throws -> String {
        var comps = URLComponents(url: endpoints.finishUpload, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "parts", value: String(parts)),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        authorize(&req)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw BakeError.finishFailed(
                status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let callID = obj["call_id"] as? String, !callID.isEmpty
        else {
            throw BakeError.noCallID
        }
        return callID
    }

    private func pollResult(callID: String, session: URLSession,
                            progress: @escaping (Stage) -> Void) async throws -> Data {
        var comps = URLComponents(url: endpoints.result, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "call_id", value: callID)]
        let url = comps.url!
        let deadline = Date().addingTimeInterval(bakeTimeout)

        while Date() < deadline {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            authorize(&req)
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1

            switch status {
            case 200:
                progress(.downloading)
                return data
            case 202:
                progress(.baking)
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            default:
                throw BakeError.bakeServerError(
                    status: status, body: String(data: data, encoding: .utf8) ?? "")
            }
        }
        throw BakeError.timedOut(seconds: Int(bakeTimeout))
    }

    /// Best-effort download of the bake's USDZ twin (served once by /usdz,
    /// then deleted server-side). Saved as vista_bakes/<name>.usdz so the
    /// Library can offer "View in AR" on baked rows.
    private func downloadUSDZTwin(id: String, named name: String,
                                  session: URLSession) async {
        var comps = URLComponents(url: endpoints.usdz, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "id", value: id)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        authorize(&req)
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty else { return }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("vista_bakes", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(name).usdz")
        try? fm.removeItem(at: dest)
        try? data.write(to: dest, options: .atomic)
    }

    // MARK: Helpers

    /// Zips a directory to a temp .zip using NSFileCoordinator's `.forUploading`
    /// option — the system builds a zip of the folder (top entry = folder name),
    /// which the server's `_run_pipeline` tolerates (it looks for manifest.json at
    /// the zip root OR one directory down).
    static func zipDirectory(_ dir: URL) throws -> URL {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var produced: URL?
        var moveError: Error?

        coordinator.coordinate(readingItemAt: dir, options: [.forUploading],
                               error: &coordError) { tmpZip in
            // tmpZip is valid only inside this block; move it out synchronously.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(dir.lastPathComponent)-\(UUID().uuidString).zip")
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tmpZip, to: dest)
                produced = dest
            } catch {
                moveError = error
            }
        }

        if let e = coordError { throw BakeError.zipFailed(e.localizedDescription) }
        if let e = moveError { throw BakeError.zipFailed(e.localizedDescription) }
        guard let zip = produced else {
            throw BakeError.zipFailed("coordinator produced no archive")
        }
        return zip
    }

    /// Saves the GLB bytes to Documents/vista_bakes/<name>.glb.
    static func saveGLB(_ data: Data, named name: String) throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("vista_bakes", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(name).glb")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try data.write(to: dest, options: .atomic)
        return dest
    }
}
