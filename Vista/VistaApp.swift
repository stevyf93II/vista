//
//  VistaApp.swift
//  Vista
//
//  Created by user281943 on 6/4/26.
//
//  2026-06-10: launch-time tmp sweep. Scan sessions stage their working
//  folders (vista_room_<ts>, vista_obj_*) in tmp; iOS only purges tmp under
//  storage pressure, so gigabytes of dead frames accumulated invisibly
//  (the Files app can't see tmp). tmp contents are disposable by contract
//  and nothing is mid-scan at launch, so a full sweep is safe.
//
//  2026-06-11: VISTA 3D theme phase 1 (Design Board v1, approved) —
//  dark-only color scheme (the brand IS the dark room), global Vista Teal
//  tint, opaque Ink tab/nav bar chrome. Tokens live in Theme.swift.
//

import SwiftUI
import UIKit

@main
struct VistaApp: App {

    init() {
        Self.sweepTemporaryDirectory()
        Self.applyVistaChrome()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)   // Vista is dark-only by design
                .tint(VistaTheme.teal)
        }
    }

    /// Ink-colored opaque tab + nav bars (UIKit appearance — SwiftUI offers
    /// no direct hook for tab bar background color).
    private static func applyVistaChrome() {
        let ink = UIColor(red: 11/255, green: 16/255, blue: 20/255, alpha: 1)

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = ink
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = ink
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    /// Delete everything in the app's tmp directory on a background queue.
    private static func sweepTemporaryDirectory() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            guard let items = try? fm.contentsOfDirectory(
                at: tmp, includingPropertiesForKeys: nil) else { return }
            var freed: Int64 = 0
            for item in items {
                if let size = try? fm.allocatedSizeOfDirectory(at: item) {
                    freed += size
                }
                try? fm.removeItem(at: item)
            }
            if freed > 0 {
                print("[vista] tmp sweep freed ~\(freed / 1_000_000) MB")
            }
        }
    }
}

private extension FileManager {
    /// Best-effort recursive size of a file or directory.
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        var isDir: ObjCBool = false
        guard fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try attributesOfItem(atPath: url.path)
            return Int64((attrs[.size] as? Int) ?? 0)
        }
        var total: Int64 = 0
        if let enumerator = self.enumerator(at: url,
                                            includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                    total += Int64(size)
                }
            }
        }
        return total
    }
}
