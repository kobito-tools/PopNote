import Cocoa
import WebKit

// 画面と同じ経路（popnote-page:// → PageSchemeHandler → MemoRouter → LocalMemoStore）でAPIを試す。
// 使い方: harness <シナリオ.js> <保存先にするフォルダ>
@MainActor final class Harness: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private let handler: PageSchemeHandler
    private let script: String
    private let basePath: String
    private var started = false

    init(web: URL, schema: URL, script: String, basePath: String) {
        self.script = script
        self.basePath = basePath
        handler = PageSchemeHandler(webRoot: web, router: MemoRouter(schemaDirectory: schema))
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: PageSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: "\(PageSchemeHandler.origin)/index.html")!))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard !started else { return }
            started = true
            do {
                let result = try await webView.callAsyncJavaScript(script, arguments: ["basePath": basePath], in: nil, contentWorld: .page)
                print(result ?? "")
                exit(0)
            } catch {
                print("FAILED: \(error)")
                exit(1)
            }
        }
    }
}

let arguments = CommandLine.arguments
let root = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let harness = MainActor.assumeIsolated {
    Harness(web: root.appendingPathComponent("web"), schema: root.appendingPathComponent("schema"),
            script: try! String(contentsOfFile: arguments[1], encoding: .utf8), basePath: arguments[2])
}
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("FAILED: timeout"); exit(1) }
application.run()
