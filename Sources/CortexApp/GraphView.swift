import SwiftUI
import WebKit

/// Hosts the three.js graph (web/index.html) and relays its messages to the model.
struct GraphView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "cortex")
        config.userContentController.addUserScript(WKUserScript(source: """
            window.addEventListener('error', e => window.webkit.messageHandlers.cortex.postMessage({type: 'log', message: String(e.message)}));
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.clipsToBounds = true // macOS 14+ no longer clips by default; the canvas would spill over the inspector
        model.webView = webView

        let dir = Self.webDirectory
        webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// Bundled `Resources/web` in the .app, or the repo's `web/` folder when run from `swift run`.
    static var webDirectory: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("web")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let model: AppModel
        init(model: AppModel) { self.model = model }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            MainActor.assumeIsolated {
                switch type {
                case "ready": model.graphDidLoad()
                case "select": model.select(body["id"] as? String)
                case "log": print("[graph] \(body["message"] ?? "")")
                default: break
                }
            }
        }
    }
}
