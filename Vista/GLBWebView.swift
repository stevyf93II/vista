//
//  GLBWebView.swift
//  Vista
//
//  In-app viewer for a baked room GLB (roadmap #2 piece 3).
//
//  QuickLook / RealityKit cannot render glTF/GLB natively (they want USDZ), so
//  the baked GLB is shown in a WKWebView running the bundled three.js viewer
//  (vista_viewer.html). That page loads three.js as CLASSIC (non-module) scripts
//  from a CDN — modules/import-maps are flaky in a file:// WKWebView, classic
//  scripts are not. Needs network on first view (the device just baked online).
//  The viewer prints on-screen status/errors instead of failing to a grey screen.
//
//  Loading a local file into a file:// WKWebView via XHR is blocked by WebKit,
//  so instead the page signals readiness (webkit.messageHandlers.glbReady) and
//  we push the GLB bytes in as base64 via evaluateJavaScript. A ~5 MB GLB is
//  ~6.7 MB of base64 — fine for a one-shot injection.
//

import SwiftUI
import WebKit

struct GLBWebView: UIViewRepresentable {
    let glbURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(glbURL: glbURL) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.add(context.coordinator, name: "glbReady")

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.106, green: 0.114, blue: 0.133, alpha: 1)
        web.scrollView.bounces = false
        // Allow Safari Web Inspector (Mac → Develop menu) to attach to this view.
        if #available(iOS 16.4, *) { web.isInspectable = true }
        context.coordinator.webView = web

        if let html = Bundle.main.url(forResource: "vista_viewer", withExtension: "html") {
            web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        } else {
            web.loadHTMLString(
                "<body style='background:#1b1d22;color:#fff;font-family:system-ui;"
                + "display:flex;align-items:center;justify-content:center;height:100vh'>"
                + "<p>viewer asset (vista_viewer.html) not bundled</p></body>",
                baseURL: nil)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        // If the GLB changes while mounted, re-arm injection.
        if context.coordinator.glbURL != glbURL {
            context.coordinator.glbURL = glbURL
            context.coordinator.injected = false
            context.coordinator.injectIfReady()
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "glbReady")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var glbURL: URL
        weak var webView: WKWebView?
        var injected = false
        private var pageReady = false

        init(glbURL: URL) { self.glbURL = glbURL }

        // Page signalled three.js is initialized and the loader hook is live.
        func userContentController(_ uc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "glbReady" {
                pageReady = true
                injectIfReady()
            }
        }

        // Fallback: if the readiness ping never arrives (e.g. message-handler name
        // drift), try once after the page finishes loading.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, !self.injected else { return }
                self.pageReady = true
                self.injectIfReady()
            }
        }

        func injectIfReady() {
            guard pageReady, !injected, let web = webView else { return }
            guard let data = try? Data(contentsOf: glbURL) else { return }
            injected = true
            let b64 = data.base64EncodedString()
            let name = glbURL.lastPathComponent
            let js = "window.loadBase64GLB && window.loadBase64GLB('\(b64)','\(name)');"
            web.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

/// Modal screen that shows a baked GLB with a Done button.
struct GLBViewerScreen: View {
    let glbURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GLBWebView(glbURL: glbURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Baked Room")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
