import Foundation
import WebKit

/// `popnote-page://app/` でアプリ内の画面ファイルを配信し、`/api/…` を MemoRouter へ渡す。
/// Tomelet のトークンや保存先の絶対パスの扱いは Swift 側だけで行う。
@MainActor
final class PageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "popnote-page"
    static let origin = "\(scheme)://app"

    private let webRoot: URL
    private let router: MemoRouter
    private var activeTasks = Set<ObjectIdentifier>()
    private static let securityPolicy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"

    init(webRoot: URL, router: MemoRouter) {
        self.webRoot = webRoot.standardizedFileURL
        self.router = router
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        activeTasks.insert(ObjectIdentifier(task))
        guard let url = task.request.url else { return respond(task, URL(string: Self.origin)!, 400, "text/plain", Data()) }
        guard url.path.hasPrefix("/api/") else { return serveFile(task, url) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" } ?? [:]
        let request = StoreRequest(method: task.request.httpMethod ?? "GET", route: String(url.path.dropFirst("/api/".count)), query: query, body: body(of: task.request))
        Task { @MainActor in
            let response = await router.handle(request)
            respond(task, url, response.status, response.contentType, response.body)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(task))
    }

    private func serveFile(_ task: WKURLSchemeTask, _ url: URL) {
        let relative = url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let file = webRoot.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(webRoot.path + "/"), let data = try? Data(contentsOf: file) else { return respond(task, url, 404, "text/plain", Data()) }
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "svg": "image/svg+xml", "png": "image/png"]
        respond(task, url, 200, types[file.pathExtension] ?? "application/octet-stream", data, ["Content-Security-Policy": Self.securityPolicy])
    }

    private func body(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func respond(_ task: WKURLSchemeTask, _ url: URL, _ status: Int, _ contentType: String, _ data: Data, _ extra: [String: String] = [:]) {
        let key = ObjectIdentifier(task)
        guard activeTasks.contains(key) else { return }
        activeTasks.remove(key)
        let headers = ["Content-Type": contentType, "Cache-Control": "no-store"].merging(extra) { _, new in new }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }
}
