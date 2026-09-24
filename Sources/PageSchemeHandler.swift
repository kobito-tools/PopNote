import Foundation
import WebKit

/// `popnote-page://app/` でアプリ内の画面ファイルを配信し、`/api/…` をTick Tock Tomeの連携APIへ中継する。
/// トークンはここで付けるため、画面のJavaScriptには渡らない。
final class PageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "popnote-page"
    static let origin = "\(scheme)://app"

    private let webRoot: URL
    private var connection: TickTockTomeConnection?
    private var activeTasks = Set<ObjectIdentifier>()
    private let session = URLSession(configuration: .ephemeral)
    private static let uploadContent = try! NSRegularExpression(pattern: "^/api/v1/uploads/upload-[0-9a-f-]{36}/content$")
    private static let securityPolicy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"

    init(webRoot: URL) { self.webRoot = webRoot.standardizedFileURL }

    func connect(_ connection: TickTockTomeConnection) { self.connection = connection }

    /// ページ上のアップロード画像などを、ブラウザで開くための実URLへ変換する。
    func serverURL(for pageURL: URL) -> URL? {
        guard let connection, pageURL.scheme == Self.scheme, matches(Self.uploadContent, pageURL.path) else { return nil }
        return URL(string: "http://127.0.0.1:\(connection.port)\(pageURL.path)")
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        activeTasks.insert(ObjectIdentifier(task))
        guard let url = task.request.url else { return fail(task, 400) }
        if url.path.hasPrefix("/api/") { relay(task, url) } else { serveFile(task, url) }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(task))
    }

    // MARK: - 画面ファイル

    private func serveFile(_ task: WKURLSchemeTask, _ url: URL) {
        let relative = url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let file = webRoot.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(webRoot.path + "/"), let data = try? Data(contentsOf: file) else { return fail(task, 404) }
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "svg": "image/svg+xml", "png": "image/png"]
        respond(task, url, 200, ["Content-Type": types[file.pathExtension] ?? "application/octet-stream", "Content-Security-Policy": Self.securityPolicy, "Cache-Control": "no-store"], data)
    }

    // MARK: - Tick Tock Tomeへの中継

    private func relay(_ task: WKURLSchemeTask, _ url: URL) {
        guard let connection else { return respondJSON(task, url, 503, "Tick Tock Tomeへ接続中です。") }
        // 本文に埋め込んだ画像は公開済みの配信URLへ、それ以外は/api/v1/integrations/memo/配下へ送る。
        let isUpload = task.request.httpMethod == "GET" && matches(Self.uploadContent, url.path)
        let path = isUpload ? url.path : "/api/v1/integrations/memo/" + url.path.dropFirst("/api/".count)
        var components = URLComponents(string: "http://127.0.0.1:\(connection.port)\(path)")!
        components.percentEncodedQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        guard let target = components.url else { return fail(task, 400) }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        request.httpMethod = task.request.httpMethod ?? "GET"
        request.httpBody = body(of: task.request)
        if request.httpBody != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if !isUpload { request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization") }
        let key = ObjectIdentifier(task)
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.activeTasks.contains(key) else { return }
                guard let http = response as? HTTPURLResponse else {
                    return self.respondJSON(task, url, 502, "Tick Tock Tomeに接続できません。Tick Tock Tomeが終了していないか確認してください。")
                }
                let type = http.value(forHTTPHeaderField: "Content-Type") ?? "application/json; charset=utf-8"
                self.respond(task, url, http.statusCode, ["Content-Type": type, "Cache-Control": "no-store"], data ?? Data())
            }
        }.resume()
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

    // MARK: - 応答

    private func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private func respondJSON(_ task: WKURLSchemeTask, _ url: URL, _ status: Int, _ message: String) {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        respond(task, url, status, ["Content-Type": "application/json; charset=utf-8"], data)
    }

    private func fail(_ task: WKURLSchemeTask, _ status: Int) {
        respond(task, task.request.url ?? URL(string: Self.origin)!, status, ["Content-Type": "text/plain; charset=utf-8"], Data())
    }

    private func respond(_ task: WKURLSchemeTask, _ url: URL, _ status: Int, _ headers: [String: String], _ data: Data) {
        let key = ObjectIdentifier(task)
        guard activeTasks.contains(key) else { return }
        activeTasks.remove(key)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
