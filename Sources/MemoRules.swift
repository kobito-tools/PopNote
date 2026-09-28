import Foundation

/// Tomeletのscripts/services/memo-service.jsと同じ規則。どちらのアプリが保存しても同じ内容になるようにする。
enum MemoRules {
    // 装飾4種・改行・段落・箇条書きと、このデータセットにアップロードした画像だけを残し、属性や他のタグは捨てる。
    private static let allowedTags: [String: String] = [
        "b": "b", "strong": "b", "i": "i", "em": "i", "u": "u", "s": "s", "strike": "s", "del": "s",
        "br": "br", "div": "div", "p": "div", "ul": "ul", "ol": "ol", "li": "li", "img": "img",
    ]
    private static let voidTags: Set<String> = ["br", "img"]
    private static let tagPattern = try! NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9]*)\\b([^>]*)>|<!--[\\s\\S]*?-->")
    private static let srcPattern = try! NSRegularExpression(pattern: "\\bsrc\\s*=\\s*\"([^\"]*)\"", options: .caseInsensitive)
    private static let uploadSource = try! NSRegularExpression(pattern: "^/api/v1/uploads/(upload-[0-9a-f-]{36})/content$")
    private static let bareAmpersand = try! NSRegularExpression(pattern: "&(?!(?:[A-Za-z][A-Za-z0-9]{1,31}|#\\d{1,7}|#x[0-9A-Fa-f]{1,6});)")
    private static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,200}$")
    static let maxBodyLength = 1_000_000

    private static func groups(_ expression: NSRegularExpression, _ value: String) -> [String]? {
        let text = value as NSString
        guard let match = expression.firstMatch(in: value, range: NSRange(location: 0, length: text.length)) else { return nil }
        return (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : text.substring(with: match.range(at: $0)) }
    }

    private static func escapeText(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return bareAmpersand.stringByReplacingMatches(in: escaped, range: NSRange(location: 0, length: (escaped as NSString).length), withTemplate: "&amp;")
    }

    static func sanitize(_ input: String) throws -> (html: String, uploadIds: [String]) {
        guard (input as NSString).length <= maxBodyLength else { throw StoreError.badRequest("メモ本文が長すぎます。") }
        let source = input as NSString
        var output = "", open: [String] = [], uploadIds: [String] = [], last = 0
        for match in tagPattern.matches(in: input, range: NSRange(location: 0, length: source.length)) {
            output += escapeText(source.substring(with: NSRange(location: last, length: match.range.location - last)))
            last = match.range.location + match.range.length
            guard match.range(at: 2).location != NSNotFound else { continue }
            let closing = source.substring(with: match.range(at: 1)) == "/"
            guard let tag = allowedTags[source.substring(with: match.range(at: 2)).lowercased()] else { continue }
            if closing {
                guard let index = open.lastIndex(of: tag) else { continue }
                while open.count > index { output += "</\(open.removeLast())>" }
                continue
            }
            if tag == "img" {
                let attributes = match.range(at: 3).location == NSNotFound ? "" : source.substring(with: match.range(at: 3))
                guard let src = groups(srcPattern, attributes)?[1], let upload = groups(uploadSource, src) else { continue }
                if !uploadIds.contains(upload[1]) { uploadIds.append(upload[1]) }
                output += "<img src=\"\(src)\" alt=\"\">"
                continue
            }
            output += "<\(tag)>"
            if !voidTags.contains(tag) { open.append(tag) }
        }
        output += escapeText(source.substring(from: last))
        while let tag = open.popLast() { output += "</\(tag)>" }
        return (output, uploadIds)
    }

    private static func decodeEntities(_ value: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        let expression = try! NSRegularExpression(pattern: "&(#x[0-9A-Fa-f]+|#\\d+|[A-Za-z]+);")
        let text = value as NSString
        var output = "", last = 0
        for match in expression.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            output += text.substring(with: NSRange(location: last, length: match.range.location - last))
            let code = text.substring(with: match.range(at: 1)), whole = text.substring(with: match.range)
            if code.hasPrefix("#") {
                let point = code.hasPrefix("#x") ? UInt32(code.dropFirst(2), radix: 16) : UInt32(code.dropFirst())
                output += point.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? whole
            } else { output += named[code] ?? whole }
            last = match.range.location + match.range.length
        }
        return output + text.substring(from: last)
    }

    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<img[^>]*>", with: "［画像］", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(?:br|/div|/li)>", with: "\n", options: .regularExpression)
        text = decodeEntities(text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 見出しの初期値はこのMacの現地時刻で「09月23日14時05分07秒のノート」とする。
    static func defaultTitle(_ createdAt: Date) -> String {
        let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute, .second], from: createdAt)
        return String(format: "%02d月%02d日%02d時%02d分%02d秒のノート", parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!)
    }

    private static func idList(_ value: Any?, _ label: String) throws -> [String] {
        var list: [String] = []
        for item in (value as? [Any] ?? []).map({ String(describing: $0) }) where !list.contains(item) { list.append(item) }
        guard list.count <= 500, list.allSatisfy({ groups(idPattern, $0) != nil }) else { throw StoreError.badRequest("\(label)の指定が正しくありません。") }
        return list
    }

    struct Input {
        var createdAt: String?
        let title: String
        let bodyHtml: String
        let bodyText: String
        let tagIds: [String]
        let managedFileIds: [String]
        let uploadIds: [String]
        var revision: Int?
    }

    static func validate(_ body: [String: Any], editing: Bool, now: Date = Date()) throws -> Input {
        var createdAt: Date? = nil
        if !editing {
            if let value = body["createdAt"] as? String {
                guard value.range(of: "^\\d{4}-\\d{2}-\\d{2}T", options: .regularExpression) != nil, let parsed = Dataset.parseTimestamp(value), parsed <= now.addingTimeInterval(60) else {
                    throw StoreError.badRequest("メモの作成日時が正しくありません。")
                }
                createdAt = parsed
            } else { createdAt = now }
        }
        let requested = String((body["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        let title = !requested.isEmpty ? requested : createdAt.map(defaultTitle) ?? ""
        guard !title.isEmpty else { throw StoreError.badRequest("見出しを入力してください。") }
        let (html, inlineUploads) = try sanitize(body["bodyHtml"] as? String ?? "")
        var uploads = try idList(body["uploadIds"], "添付画像")
        for id in inlineUploads where !uploads.contains(id) { uploads.append(id) }
        var input = Input(createdAt: createdAt.map { Dataset.timestamp($0) }, title: title, bodyHtml: html, bodyText: plainText(html),
                          tagIds: try idList(body["tagIds"], "タグ"), managedFileIds: try idList(body["managedFileIds"], "添付ファイル"), uploadIds: uploads)
        if editing {
            guard let revision = (body["revision"] as? Int) ?? Int(String(describing: body["revision"] ?? "")), revision >= 1 else {
                throw StoreError.badRequest("更新情報が正しくありません。再読み込みしてください。")
            }
            input.revision = revision
        }
        return input
    }
}
