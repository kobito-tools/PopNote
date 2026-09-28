import Cocoa
import WebKit

// README用のデモGIFの素材を撮る。本物の画面（popnote-page:// → MemoRouter → LocalMemoStore）を、
// 一時フォルダの保存先で動かし、画面外のウィンドウから一定間隔で撮影する。PopNote!本体の設定には触れない。
// 使い方: recorder <準備.js> <演出.js> <保存先にするフォルダ> <画像の出力先> <秒数>
@MainActor final class Recorder: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private let handler: PageSchemeHandler
    private let setup: String, director: String, basePath: String, output: URL, seconds: Double
    private var loads = 0
    private var frame = 0

    init(web: URL, schema: URL, setup: String, director: String, basePath: String, output: URL, seconds: Double) {
        self.setup = setup; self.director = director; self.basePath = basePath; self.output = output; self.seconds = seconds
        handler = PageSchemeHandler(webRoot: web, router: MemoRouter(schemaDirectory: schema))
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: PageSchemeHandler.scheme)
        // 本物と同じウィンドウの大きさ（PopNoteApp.swift）。画面の外に置いて撮る。
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 760, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 620), configuration: configuration)
        super.init()
        window.contentView = webView
        window.orderFrontRegardless()
        window.makeKey()
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: "\(PageSchemeHandler.origin)/index.html")!))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            loads += 1
            if loads == 1 {
                // 1回目：保存先を作ってデモ用のメモを入れ、読み込み直して「保存先あり」の状態から始める。
                do { _ = try await webView.callAsyncJavaScript(setup, arguments: ["basePath": basePath], in: nil, contentWorld: .page) }
                catch { print("FAILED setup: \(error)"); exit(1) }
                webView.reload()
            } else if loads == 2 {
                try? await Task.sleep(for: .milliseconds(600))
                _ = try? await webView.evaluateJavaScript(director)
                capture()
            }
        }
    }

    private func capture() {
        webView.evaluateJavaScript("window.__demoStep(\(frame))", completionHandler: nil)
        // 操作の結果（画面の書き換え・保存の応答）が描画されるのを少し待ってから撮る。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.snapshot() }
    }

    private func snapshot() {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 760
        webView.takeSnapshot(with: configuration) { [self] image, _ in
            if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: output.appendingPathComponent(String(format: "frame_%04d.png", frame)))
            }
            frame += 1
            if Double(frame) / 10 >= seconds { print("frames: \(frame)"); exit(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.capture() }
        }
    }
}

let arguments = CommandLine.arguments
let root = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let recorder = MainActor.assumeIsolated {
    Recorder(web: root.appendingPathComponent("web"), schema: root.appendingPathComponent("schema"),
             setup: try! String(contentsOfFile: arguments[1], encoding: .utf8),
             director: try! String(contentsOfFile: arguments[2], encoding: .utf8),
             basePath: arguments[3], output: URL(fileURLWithPath: arguments[4]), seconds: Double(arguments[5]) ?? 12)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("FAILED: timeout"); exit(1) }
application.run()
