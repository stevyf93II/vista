//
//  ContentView.swift
//  Vista
//
//  Root view. Four tabs:
//    - Room    → RoomCaptureView   (RoomPlan, Day 3-4)
//    - Object  → ObjectCaptureView (Object Capture, Day 5-6)
//    - Library → LibraryView       (capture history + test upload, Day 2/7)
//    - Settings → SettingsView     (Render backend config, Day 2)
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RoomCaptureView()
                .tabItem {
                    Label("Room", systemImage: "house.fill")
                }

            ObjectCaptureView()
                .tabItem {
                    Label("Object", systemImage: "cube.fill")
                }

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "photo.stack.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}

#Preview {
    ContentView()
}
