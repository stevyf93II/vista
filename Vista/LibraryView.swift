//
//  LibraryView.swift
//  Vista
//
//  Day 8 — Local-first scan library with in-app viewer.
//  Day 9.1 — Fix QuickLook X-button dismiss for Object scans.
//  Day 12 (2026-06-07) — Room scans route to a SwiftUI SCNView (no AR) per
//    Steve's request. Object scans continue using QuickLook (AR retained).
//  Phase 6 (2026-06-09) — Library also lists cloud bakes
//    (Documents/vista_bakes/*.glb) and opens them in GLBViewerScreen, so a
//    finished bake survives the Room tab's phase reset / app restart.
//  2026-06-10 — QuickLook escape hatch: QLPreviewController shows no Done
//    chrome inside a fullScreenCover on iOS 18; an overlaid X button now
//    always offers a way out.
//  2026-06-11 — 3D/AR CHOICE for every USDZ scan (rooms AND objects).
//  2026-06-11b — VISTA TOUCH: the bottom confirmationDialog is gone —
//    tapping a scan expands TWO TILES right under the row (View in 3D /
//    View in AR), and both routes now use OUR viewers (VistaViewers.swift):
//    orbit-locked 3D with momentum + rubber-band zoom, and space-mapped AR
//    with dollhouse rooms. QuickLook is fully retired from the Library.
//  2026-06-11c — tiles are tap-gesture views, NOT Buttons (List row
//    hit-testing swallowed Button taps = dead "View in 3D"); bakes expand
//    too, with a single 3D tile into the teal GLB viewer.
//

import SwiftUI
import UIKit

// MARK: - Storage helper (file-level so the capture views can also reach it)

enum ScansStorage {
    static var scansFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("vista_scans", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    /// Where BakeUploader.saveGLB writes finished cloud bakes.
    static var bakesFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("vista_bakes", isDirectory: true)
    }

    @discardableResult
    static func saveCopy(of file: URL) throws -> URL {
        let dest = scansFolder.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: file, to: dest)
        return dest
    }

    static func listScans() -> [Scan] {
        var items: [Scan] = []

        if let contents = try? FileManager.default.contentsOfDirectory(
            at: scansFolder,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            items += contents
                .filter { $0.pathExtension.lowercased() == "usdz" }
                .map { url -> Scan in
                    let attrs = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                    return Scan(
                        url: url,
                        name: url.deletingPathExtension().lastPathComponent,
                        createdAt: attrs?.creationDate ?? Date(),
                        sizeBytes: attrs?.fileSize ?? 0,
                        kind: .scan
                    )
                }
        }

        // Cloud bakes: textured GLBs from the Modal pipeline.
        if let bakes = try? FileManager.default.contentsOfDirectory(
            at: bakesFolder,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            items += bakes
                .filter { $0.pathExtension.lowercased() == "glb" }
                .map { url -> Scan in
                    let attrs = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                    return Scan(
                        url: url,
                        name: url.deletingPathExtension().lastPathComponent,
                        createdAt: attrs?.creationDate ?? Date(),
                        sizeBytes: attrs?.fileSize ?? 0,
                        kind: .bake
                    )
                }
        }

        return items.sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(_ scan: Scan) throws {
        try FileManager.default.removeItem(at: scan.url)
    }
}

struct Scan: Identifiable, Hashable {
    enum Kind: Hashable {
        case scan   // USDZ in vista_scans
        case bake   // textured GLB in vista_bakes (cloud bake output)
    }

    var id: URL { url }
    let url: URL
    let name: String
    let createdAt: Date
    let sizeBytes: Int
    let kind: Kind

    var sizeString: String {
        let mb = Double(sizeBytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(sizeBytes) / 1024
        return String(format: "%.0f KB", kb)
    }

    var isRoomScan: Bool { name.hasPrefix("vista_room") || name == "room" || name.hasPrefix("room") }
}

// MARK: - Library view

/// Which viewer a scan opens in. USDZ scans offer a choice; bakes are GLB.
private enum ViewerRoute: Identifiable {
    case glb(Scan)     // cloud bake -> three.js viewer
    case scene(Scan)   // "View in 3D" -> SceneKit orbit (rooms + objects)
    case ar(Scan)      // "View in AR" -> Vista Touch AR
    case arTwin(Scan)  // baked row -> AR via its downloaded USDZ twin

    var id: String {
        switch self {
        case .glb(let s):    return "glb:" + s.url.path
        case .scene(let s):  return "scene:" + s.url.path
        case .ar(let s):     return "ar:" + s.url.path
        case .arTwin(let s): return "arTwin:" + s.url.path
        }
    }
}

struct LibraryView: View {
    @AppStorage("renderBaseURL") private var renderBaseURL: String = ""
    @AppStorage("uploadToken") private var uploadToken: String = ""
    @AppStorage("slugPrefix") private var slugPrefix: String = "vista-"

    @State private var scans: [Scan] = []
    @State private var route: ViewerRoute?
    @State private var expandedID: URL?    // row with 3D/AR tiles open
    @State private var sharingScan: Scan?
    @State private var sharedURL: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if scans.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(scans) { scan in
                            VStack(spacing: 0) {
                                ScanRow(scan: scan, isSharing: sharingScan?.id == scan.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.snappy(duration: 0.22)) {
                                            expandedID = (expandedID == scan.url) ? nil : scan.url
                                        }
                                    }
                                // Vista Touch: viewer tiles drop in right
                                // under the tapped row — no reaching for a
                                // sheet at the bottom of the screen. Baked
                                // GLBs open in the teal Vista viewer (GLB
                                // can't feed SceneKit/RealityKit; AR for
                                // bakes arrives with USDZ-from-bake).
                                if expandedID == scan.url {
                                    HStack(spacing: 10) {
                                        if scan.kind == .bake {
                                            ViewerTile(title: "View in 3D",
                                                       icon: "rotate.3d",
                                                       color: VistaTheme.teal) {
                                                route = .glb(scan)
                                            }
                                            // AR twin: the worker renders a
                                            // USDZ next to every new bake and
                                            // the uploader saves it beside
                                            // the GLB. Older bakes (no twin)
                                            // simply don't get the tile.
                                            if FileManager.default.fileExists(
                                                atPath: scan.url
                                                    .deletingPathExtension()
                                                    .appendingPathExtension("usdz").path) {
                                                ViewerTile(title: "View in AR",
                                                           icon: "arkit",
                                                           color: VistaTheme.orange) {
                                                    route = .arTwin(scan)
                                                }
                                            }
                                        } else {
                                            ViewerTile(title: "View in 3D",
                                                       icon: "rotate.3d",
                                                       color: VistaTheme.teal) {
                                                route = .scene(scan)
                                            }
                                            ViewerTile(title: "View in AR",
                                                       icon: "arkit",
                                                       color: VistaTheme.orange) {
                                                route = .ar(scan)
                                            }
                                        }
                                    }
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        delete(scan)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        Task { await share(scan) }
                                    } label: {
                                        Label("Share", systemImage: "arrow.up.circle")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear { refresh() }
        .fullScreenCover(item: $route) { route in
            switch route {
            case .glb(let scan):
                // Cloud bakes: three.js viewer (dollhouse default).
                GLBViewerScreen(glbURL: scan.url)
            case .scene(let scan):
                // Vista Touch 3D: orbit-locked RST with momentum.
                Vista3DViewerScreen(url: scan.url, onDismiss: {
                    self.route = nil
                })
            case .ar(let scan):
                // Vista Touch AR: space-mapped placement; rooms = dollhouse.
                VistaARViewerScreen(url: scan.url,
                                    isRoom: scan.isRoomScan,
                                    onDismiss: { self.route = nil })
            case .arTwin(let scan):
                // Baked row in AR via its USDZ twin (always dollhouse-scaled
                // when it's a room bake).
                VistaARViewerScreen(
                    url: scan.url.deletingPathExtension()
                        .appendingPathExtension("usdz"),
                    isRoom: scan.isRoomScan,
                    onDismiss: { self.route = nil })
            }
        }
        .alert("Shared",
               isPresented: Binding(get: { sharedURL != nil },
                                    set: { if !$0 { sharedURL = nil } }),
               presenting: sharedURL) { url in
            Button("Copy URL") {
                UIPasteboard.general.string = url
                sharedURL = nil
            }
            Button("OK", role: .cancel) { sharedURL = nil }
        } message: { url in
            Text(url)
        }
        .alert("Upload failed",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               presenting: errorMessage) { _ in
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 60))
                .foregroundStyle(.tint)
            Text("No scans yet")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Capture a room or object — everything lands here. Tap a scan for 3D and AR. Swipe to share or delete.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    private func refresh() {
        scans = ScansStorage.listScans()
    }

    private func delete(_ scan: Scan) {
        try? ScansStorage.delete(scan)
        if scan.kind == .bake {
            // remove the USDZ twin alongside its GLB
            try? FileManager.default.removeItem(
                at: scan.url.deletingPathExtension()
                    .appendingPathExtension("usdz"))
        }
        refresh()
    }

    private func share(_ scan: Scan) async {
        guard !uploadToken.isEmpty else {
            errorMessage = "Set Upload Token in Settings first"
            return
        }
        sharingScan = scan
        defer { sharingScan = nil }
        do {
            let service = try UploadService.fromSettings(
                baseURLString: renderBaseURL, token: uploadToken
            )
            let suffix = String(Int.random(in: 1000...9999))
            let cleanName = scan.name
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            let slug = "\(slugPrefix)\(cleanName)-\(suffix)"
            let result = try await service.uploadFile(scan.url, slug: slug)
            sharedURL = result.url
        } catch let err as UploadError {
            errorMessage = err.errorDescription ?? "\(err)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct ScanRow: View {
    let scan: Scan
    let isSharing: Bool

    private var icon: String {
        switch scan.kind {
        case .bake: return "cube.transparent"
        case .scan: return scan.isRoomScan ? "house.fill" : "cube.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if scan.kind == .bake {
                        Text("Baked 3D")
                            .foregroundStyle(.green)
                        Text("•")
                    }
                    Text(scan.createdAt, style: .relative)
                    Text("•")
                    Text(scan.sizeString)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isSharing {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Viewer tile (drops under a tapped row)

private struct ViewerTile: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    // NOT a Button: inside a List row (which already owns a tap gesture),
    // row hit-testing swallows Button taps — the "View in 3D does nothing"
    // bug. A plain view with its own tap gesture is reliable.
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(color.opacity(0.55), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

#Preview {
    LibraryView()
}
