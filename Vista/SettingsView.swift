//
//  SettingsView.swift
//  Vista
//
//  2026-06-11 VISTA 3D redesign (approved board): a settings screen a new
//  user never has to think about. The clean face is just brand + status.
//  Every connection field (bake server URL, tokens, share host) lives under
//  "Advanced setup" — cloud features are optional and off until configured.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("renderBaseURL") private var renderBaseURL: String = ""
    @AppStorage("uploadToken") private var uploadToken: String = ""
    @AppStorage("slugPrefix") private var slugPrefix: String = "vista-"
    @AppStorage("vistaUploadToken") private var vistaUploadToken: String = ""
    @AppStorage("vistaUploadAppBaseURL") private var vistaUploadAppBaseURL: String = ""

    @State private var showAdvanced = false

    private var bakeReady: Bool { !BakeUploader().token.isEmpty }
    private var shareReady: Bool { !uploadToken.isEmpty }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    brandCard
                    statusCard
                    advancedCard
                    Text("VISTA 3D · LiDAR scanning, cloud-baked.")
                        .font(.caption2)
                        .foregroundStyle(VistaTheme.text2)
                        .padding(.top, 4)
                }
                .padding(16)
            }
            .background(VistaTheme.ink)
            .navigationTitle("Settings")
        }
    }

    private var brandCard: some View {
        VStack(spacing: 14) {
            VistaMark(lineWidth: 3)
                .frame(width: 84, height: 84)
            (Text("VISTA").tracking(5).font(.system(size: 24, weight: .heavy))
             + Text(" 3D").font(.system(size: 14, weight: .heavy))
                .foregroundColor(VistaTheme.orange))
            .foregroundColor(VistaTheme.text)
            Text(versionString)
                .font(.caption.monospaced())
                .foregroundStyle(VistaTheme.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .vistaCard()
    }

    private var statusCard: some View {
        VStack(spacing: 0) {
            statusRow(name: "Vista Cloud bake", ready: bakeReady,
                      readyText: "Ready", offText: "Needs token")
            Rectangle().fill(VistaTheme.line).frame(height: 1)
                .padding(.vertical, 10)
            statusRow(name: "Customer sharing", ready: shareReady,
                      readyText: "Ready", offText: "Off")
        }
        .vistaCard()
    }

    private func statusRow(name: String, ready: Bool,
                           readyText: String, offText: String) -> some View {
        HStack {
            Circle()
                .fill(ready ? VistaTheme.teal : VistaTheme.orange)
                .frame(width: 9, height: 9)
                .shadow(color: (ready ? VistaTheme.teal : VistaTheme.orange).opacity(0.7),
                        radius: 5)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(VistaTheme.text)
            Spacer()
            Text(ready ? readyText : offText)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(ready ? VistaTheme.teal : VistaTheme.orange)
        }
    }

    private var advancedCard: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(spacing: 14) {
                field("Bake token override", text: $vistaUploadToken,
                      prompt: "compiled-in default", secure: true)
                field("Bake upload URL", text: $vistaUploadAppBaseURL,
                      prompt: "built-in default")
                field("Share URL", text: $renderBaseURL, prompt: "https://...")
                field("Share token", text: $uploadToken,
                      prompt: "enables sharing", secure: true)
                field("Slug prefix", text: $slugPrefix, prompt: "vista-")
                Text("Leave everything blank to use the built-in defaults. Override the bake token only when rotating the vista-token secret.")
                    .font(.caption2)
                    .foregroundStyle(VistaTheme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                Text("Advanced setup")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(VistaTheme.text2)
        }
        .tint(VistaTheme.text2)
        .vistaCard()
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>,
                       prompt: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(VistaTheme.text2)
            Group {
                if secure {
                    SecureField(prompt, text: text)
                } else {
                    TextField(prompt, text: text)
                        .keyboardType(.URL)
                }
            }
            .font(.footnote.monospaced())
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .padding(10)
            .background(VistaTheme.raised,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

#Preview {
    SettingsView()
}
