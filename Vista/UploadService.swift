//
//  UploadService.swift
//  Vista
//
//  Multipart POST client for the share-host upload endpoint (any compatible
//  server). Set the base URL and token in Settings.
//  Reads URL + token from settings; callers pass a local file URL and slug.
//  Used by RoomCaptureView, ObjectCaptureView, and LibraryView's test button.
//

import Foundation

struct UploadResult: Codable, Sendable {
    let filename: String
    let url: String
    let sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case filename, url
        case sizeBytes = "size_bytes"
    }
}

enum UploadError: LocalizedError {
    case invalidBaseURL(String)
    case missingToken
    case fileNotFound(URL)
    case httpError(status: Int, body: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let s): return "Invalid Render base URL: \(s)"
        case .missingToken: return "Upload token not set — open Settings"
        case .fileNotFound(let url): return "File not found: \(url.lastPathComponent)"
        case .httpError(let status, let body): return "HTTP \(status): \(body)"
        case .invalidResponse: return "Server response wasn't valid JSON"
        }
    }
}

actor UploadService {
    let baseURL: URL
    let uploadToken: String

    init(baseURL: URL, uploadToken: String) {
        self.baseURL = baseURL
        self.uploadToken = uploadToken
    }

    /// Convenience constructor that reads @AppStorage values. Throws on bad URL / empty token.
    static func fromSettings(baseURLString: String, token: String) throws -> UploadService {
        guard let url = URL(string: baseURLString) else {
            throw UploadError.invalidBaseURL(baseURLString)
        }
        guard !token.isEmpty else {
            throw UploadError.missingToken
        }
        return UploadService(baseURL: url, uploadToken: token)
    }

    /// POST <baseURL>/upload/file with a local file as the `file` multipart field
    /// and `slug` as another text field. Returns the parsed JSON response.
    func uploadFile(_ fileURL: URL, slug: String) async throws -> UploadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadError.fileNotFound(fileURL)
        }

        let endpoint = baseURL.appendingPathComponent("upload/file")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(uploadToken, forHTTPHeaderField: "X-Upload-Token")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        request.httpBody = try buildMultipartBody(
            boundary: boundary, slug: slug, fileURL: fileURL
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw UploadError.httpError(status: http.statusCode, body: bodyStr)
        }

        return try JSONDecoder().decode(UploadResult.self, from: data)
    }

    // MARK: - Multipart body construction

    private func buildMultipartBody(boundary: String, slug: String, fileURL: URL) throws -> Data {
        var body = Data()
        func appendString(_ s: String) { body.append(s.data(using: .utf8)!) }

        // slug text field
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"slug\"\r\n\r\n")
        appendString("\(slug)\r\n")

        // file binary field
        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let mime = mimeType(forExtension: fileURL.pathExtension)

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mime)\r\n\r\n")
        body.append(fileData)
        appendString("\r\n")

        // closing boundary
        appendString("--\(boundary)--\r\n")

        return body
    }

    private func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "glb":   return "model/gltf-binary"
        case "gltf":  return "model/gltf+json"
        case "usdz":  return "model/vnd.usdz+zip"
        case "ply", "splat", "ksplat", "spz": return "application/octet-stream"
        case "png":   return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "mp4":   return "video/mp4"
        case "txt":   return "text/plain"
        default:      return "application/octet-stream"
        }
    }
}
