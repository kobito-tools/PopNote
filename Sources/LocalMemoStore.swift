import Foundation

/// 画面からのAPI要求（/api/…）。routeは /api/ を除いた部分。
struct StoreRequest {
    let method: String
    let route: String
    let query: [String: String]
    let body: Data?

    func json() throws -> [String: Any] {
        guard let body, !body.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw StoreError.badRequest("JSON形式が正しくありません。") }
        return object
    }
}

struct StoreResponse {
    let status: Int
    let body: Data
    let contentType: String

    static func json(_ status: Int, _ value: Any) -> StoreResponse {
        StoreResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8), contentType: "application/json; charset=utf-8")
    }
    static func error(_ error: Error) -> StoreResponse {
        let failure = error as? StoreError ?? StoreError(status: 500, message: error.localizedDescription)
        return json(failure.status, failure.json)
    }
}

/// 保存先の .kobito-tools/PopNote/ を、PopNote!が直接読み書きする（本体は読み取り専用で開いて表示するだけ）。
/// 表の形とSQLはTomeletのscripts/repositories/sqlite-repository.jsと同じにする。
final class LocalMemoStore: @unchecked Sendable {
    let info: DatasetInfo
    private let schemaDirectory: URL
    private static let memoIdPattern = "^memo-[0-9a-f-]{36}$"

    init(info: DatasetInfo, schemaDirectory: URL) {
        self.info = info
        self.schemaDirectory = schemaDirectory
    }

    private func newId(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.lowercased())" }

    func handle(_ request: StoreRequest) -> StoreResponse {
        do {
            let parts = request.route.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if request.method == "GET", parts.count == 4, parts[0] == "v1", parts[1] == "uploads", parts[3] == "content" { return try uploadContent(parts[2]) }
            let database = try Dataset.openDatabase(info.basePath, schemaDirectory: schemaDirectory)
            let memoId = parts.count == 2 && parts[0] == "memos" && parts[1].range(of: Self.memoIdPattern, options: .regularExpression) != nil ? parts[1] : nil
            switch (request.method, request.route) {
            case ("GET", "context"):
                syncTags(database)
                return .json(200, ["dataset": ["id": info.datasetId, "key": info.key], "mode": "local", "tagCategories": try tagCategories(database), "tags": try tags(database)])
            case ("GET", "memos"):
                return .json(200, ["items": try listMemos(database, request.query)])
            case ("POST", "memos"):
                return .json(201, ["item": try createMemo(database, MemoRules.validate(request.json(), editing: false))])
            case ("POST", "tags"):
                return .json(201, ["item": try findOrCreateTag(database, request.json()["name"] as? String ?? "")])
            case ("POST", "uploads"):
                return .json(201, ["item": try createUpload(database, request.json())])
            case ("POST", "files:reference"):
                return .json(201, ["item": try createManagedFile(database, request.json()["relativePath"] as? String ?? "")])
            default: break
            }
            if let memoId {
                switch request.method {
                case "GET":
                    guard let memo = try memo(database, memoId) else { return .json(404, ["error": "メモが見つかりません。"]) }
                    return .json(200, ["item": memo])
                case "PUT": return .json(200, ["item": try updateMemo(database, memoId, MemoRules.validate(request.json(), editing: true))])
                case "DELETE": try deleteMemo(database, memoId, request.json()["revision"] as? Int ?? 0); return .json(200, ["ok": true])
                default: break
                }
            }
            return .json(404, ["error": "Not Found"])
        } catch { return .error(error) }
    }

    // MARK: - タグ

    private func tagCategories(_ database: SQLiteDatabase) throws -> [[String: Any]] {
        try database.query("SELECT id, name, description, display_order AS displayOrder, revision FROM tag_categories WHERE deleted_at IS NULL ORDER BY display_order, name")
    }

    private func tags(_ database: SQLiteDatabase, includeArchived: Bool = false) throws -> [[String: Any]] {
        try database.query("""
            SELECT t.id, t.category_id AS categoryId, t.name, t.description, t.display_order AS displayOrder,
                   c.name AS categoryName, t.revision, t.archived_at AS archivedAt
            FROM tags t LEFT JOIN tag_categories c ON c.id = t.category_id
            WHERE t.deleted_at IS NULL \(includeArchived ? "" : "AND t.archived_at IS NULL")
            ORDER BY coalesce(c.display_order, 999), t.display_order, t.name
            """)
    }

    /// 共有タグ（.kobito-tools/Tags/tags.json）と、このDBの写しを統合する。読めない場合もメモの保存は止めない。
    private func syncTags(_ database: SQLiteDatabase) {
        do { try TagStore.sync(database, basePath: info.basePath) } catch { NSLog("PopNote!: 共有タグを同期できません: \((error as? StoreError)?.message ?? error.localizedDescription)") }
    }

    // 候補を選ばずに確定した名前は、同名タグがあれば再利用し、無ければ「その他」へ作る。
    // 本体で同じ名前のタグが作られていれば再利用できるよう、先に共有タグを取り込み、作った後すぐ書き出す。
    private func findOrCreateTag(_ database: SQLiteDatabase, _ name: String) throws -> [String: Any] {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !value.isEmpty else { throw StoreError.badRequest("タグ名を入力してください。") }
        syncTags(database)
        defer { syncTags(database) }
        return try database.transaction {
            let existing = try database.first("SELECT id FROM tags WHERE name = ? AND deleted_at IS NULL", value)?["id"] as? String
            let id = existing ?? newId("tag")
            if existing == nil {
                let order = try database.first("SELECT coalesce(max(display_order), 0) + 1 AS next FROM tags WHERE category_id = 'other'")?["next"] as? Int ?? 1
                try database.run("INSERT INTO tags(id, category_id, name, description, display_order) VALUES (?, 'other', ?, '', ?)", id, value, order)
            }
            var tag = try tags(database, includeArchived: true).first { $0["id"] as? String == id } ?? [:]
            tag["created"] = existing == nil
            return tag
        }
    }

    // MARK: - メモ

    private func listMemos(_ database: SQLiteDatabase, _ query: [String: String]) throws -> [[String: Any]] {
        var conditions = ["m.deleted_at IS NULL"], parameters: [Any?] = []
        if let from = query["from"], !from.isEmpty { guard Dataset.parseTimestamp(from) != nil else { throw StoreError.badRequest("期間はISO形式の日時で指定してください。") }; conditions.append("m.created_at >= ?"); parameters.append(from) }
        if let to = query["to"], !to.isEmpty { guard Dataset.parseTimestamp(to) != nil else { throw StoreError.badRequest("期間はISO形式の日時で指定してください。") }; conditions.append("m.created_at < ?"); parameters.append(to) }
        for part in (query["q"] ?? "").split(whereSeparator: \.isWhitespace).prefix(8) {
            let like = "%" + part.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            conditions.append("(m.title LIKE ? ESCAPE '\\' OR m.body_text LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM memo_tags mt JOIN tags t ON t.id = mt.tag_id WHERE mt.memo_id = m.id AND t.name LIKE ? ESCAPE '\\'))")
            parameters += [like, like, like]
        }
        parameters.append(min(1000, max(1, Int(query["limit"] ?? "") ?? 200)))
        let sql = "SELECT m.id, m.title, substr(m.body_text, 1, 240) AS excerpt, m.created_at AS createdAt, m.updated_at AS updatedAt, m.revision FROM memos m WHERE \(conditions.joined(separator: " AND ")) ORDER BY m.updated_at DESC LIMIT ?"
        return try database.rows(sql, parameters).map { row in
            var item = row
            item["tagIds"] = try database.query("SELECT tag_id AS tagId FROM memo_tags WHERE memo_id = ? ORDER BY tag_id", row["id"] as? String).compactMap { $0["tagId"] }
            return item
        }
    }

    private func memo(_ database: SQLiteDatabase, _ id: String) throws -> [String: Any]? {
        guard var memo = try database.first("SELECT id, title, body_html AS bodyHtml, body_text AS bodyText, created_at AS createdAt, updated_at AS updatedAt, revision, deleted_at AS deletedAt FROM memos WHERE id = ? AND deleted_at IS NULL", id) else { return nil }
        memo["tagIds"] = try database.query("SELECT tag_id AS tagId FROM memo_tags WHERE memo_id = ? ORDER BY tag_id", id).compactMap { $0["tagId"] }
        let files = try database.query("SELECT f.id, f.root_id AS rootId, f.relative_path AS relativePath, f.name, f.extension FROM memo_managed_files r JOIN managed_files f ON f.id = r.managed_file_id WHERE r.memo_id = ? AND f.deleted_at IS NULL ORDER BY f.name COLLATE NOCASE", id)
        let uploads = try database.query("SELECT u.id, u.original_name AS originalName, u.mime_type AS mimeType, u.size_bytes AS sizeBytes, u.created_at AS createdAt FROM memo_uploads r JOIN managed_uploads u ON u.id = r.upload_id WHERE r.memo_id = ? AND u.deleted_at IS NULL ORDER BY u.created_at", id)
        memo["files"] = files; memo["uploads"] = uploads
        memo["managedFileIds"] = files.compactMap { $0["id"] }; memo["uploadIds"] = uploads.compactMap { $0["id"] }
        return memo
    }

    private func createMemo(_ database: SQLiteDatabase, _ input: MemoRules.Input) throws -> [String: Any] {
        let id = newId("memo")
        try database.transaction {
            try database.run("INSERT INTO memos(id, title, body_html, body_text, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)", id, input.title, input.bodyHtml, input.bodyText, input.createdAt, Dataset.timestamp())
            try replaceRelations(database, id, input)
        }
        return try memo(database, id) ?? [:]
    }

    private func updateMemo(_ database: SQLiteDatabase, _ id: String, _ input: MemoRules.Input) throws -> [String: Any] {
        try database.transaction {
            let changed = try database.run("UPDATE memos SET title = ?, body_html = ?, body_text = ?, updated_at = ?, revision = revision + 1 WHERE id = ? AND revision = ? AND deleted_at IS NULL", input.title, input.bodyHtml, input.bodyText, Dataset.timestamp(), id, input.revision)
            guard changed == 1 else { throw StoreError(status: 409, message: "メモが別の画面で更新されたか、削除されています。再読み込みしてください。") }
            try replaceRelations(database, id, input)
        }
        return try memo(database, id) ?? [:]
    }

    private func replaceRelations(_ database: SQLiteDatabase, _ id: String, _ input: MemoRules.Input) throws {
        // アーカイブ済みのタグは画面に出ないため、編集しても外さない。
        let archived = try database.query("SELECT r.tag_id AS tagId FROM memo_tags r JOIN tags t ON t.id = r.tag_id WHERE r.memo_id = ? AND t.archived_at IS NOT NULL", id).compactMap { $0["tagId"] as? String }
        try database.run("DELETE FROM memo_tags WHERE memo_id = ?", id)
        for tagId in Array(NSOrderedSet(array: input.tagIds + archived)) { try database.run("INSERT INTO memo_tags(memo_id, tag_id) VALUES (?, ?)", id, tagId as? String) }
        try database.run("DELETE FROM memo_managed_files WHERE memo_id = ?", id)
        for fileId in input.managedFileIds { try database.run("INSERT INTO memo_managed_files(memo_id, managed_file_id) VALUES (?, ?)", id, fileId) }
        try database.run("DELETE FROM memo_uploads WHERE memo_id = ?", id)
        for uploadId in input.uploadIds { try database.run("INSERT INTO memo_uploads(memo_id, upload_id) VALUES (?, ?)", id, uploadId) }
    }

    private func deleteMemo(_ database: SQLiteDatabase, _ id: String, _ revision: Int) throws {
        let now = Dataset.timestamp()
        guard try database.run("UPDATE memos SET deleted_at = ?, updated_at = ?, revision = revision + 1 WHERE id = ? AND revision = ? AND deleted_at IS NULL", now, now, id, revision) == 1 else {
            throw StoreError(status: 409, message: "メモを削除できません。再読み込みしてください。")
        }
    }

    // MARK: - 添付

    /// 保存先フォルダからの相対パスだけを記録する（本体と同じくrootIdは "base"）。
    private func createManagedFile(_ database: SQLiteDatabase, _ relativePath: String) throws -> [String: Any] {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw StoreError.badRequest("ファイルの相対パスが正しくありません。") }
        let name = (path as NSString).lastPathComponent, ext = name.contains(".") ? (name as NSString).pathExtension.lowercased() : ""
        let select = "SELECT id, 'managed' AS sourceType, root_id AS rootId, relative_path AS relativePath, name, extension, created_at AS createdAt, revision AS metadataRevision FROM managed_files WHERE root_id = 'base' AND relative_path = ? AND deleted_at IS NULL"
        if let existing = try database.first(select, path) { return existing }
        let now = Dataset.timestamp()
        try database.run("INSERT INTO managed_files(id, root_id, relative_path, name, extension, created_at, updated_at) VALUES (?, 'base', ?, ?, ?, ?, ?)", newId("managed-file"), path, name, ext, now, now)
        return try database.first(select, path) ?? [:]
    }

    private static let imageExtensions = ["image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp", "image/heic": ".heic"]

    private func createUpload(_ database: SQLiteDatabase, _ body: [String: Any]) throws -> [String: Any] {
        let mimeType = (body["mimeType"] as? String ?? "").lowercased()
        guard let ext = Self.imageExtensions[mimeType] else { throw StoreError.badRequest("メモへ貼り付けられるのは画像だけです。") }
        let originalName = String(((body["name"] as? String ?? "") as NSString).lastPathComponent.prefix(300))
        guard !originalName.isEmpty, let base64 = body["base64"] as? String, let bytes = Data(base64Encoded: base64), !bytes.isEmpty else { throw StoreError.badRequest("アップロードデータを読み取れません。") }
        guard bytes.count <= 25 * 1024 * 1024 else { throw StoreError.badRequest("ファイルは25MB以下にしてください。") }
        let id = newId("upload"), storedName = UUID().uuidString.lowercased() + ext
        let destination = Dataset.uploadsDirectory(info.basePath).appendingPathComponent(storedName)
        guard FileManager.default.createFile(atPath: destination.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw StoreError(status: 500, message: "画像を保存できませんでした。") }
        do {
            try database.run("INSERT INTO managed_uploads(id, stored_name, original_name, mime_type, size_bytes, created_at) VALUES (?, ?, ?, ?, ?, ?)", id, storedName, originalName, mimeType, bytes.count, Dataset.timestamp())
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return try database.first("SELECT id, stored_name AS storedName, original_name AS originalName, mime_type AS mimeType, size_bytes AS sizeBytes, created_at AS createdAt FROM managed_uploads WHERE id = ?", id) ?? [:]
    }

    /// 本文の画像（/api/v1/uploads/<id>/content）を、保存先の .kobito-tools/PopNote/uploads/ から返す。
    func uploadFile(_ id: String) throws -> (url: URL, mimeType: String) {
        guard id.range(of: "^upload-[0-9a-f-]{36}$", options: .regularExpression) != nil else { throw StoreError(status: 404, message: "ファイルが見つかりません。") }
        let database = try Dataset.openDatabase(info.basePath, schemaDirectory: schemaDirectory)
        guard let row = try database.first("SELECT stored_name AS storedName, mime_type AS mimeType FROM managed_uploads WHERE id = ? AND deleted_at IS NULL", id),
              let stored = row["storedName"] as? String, !stored.contains("/") else { throw StoreError(status: 404, message: "ファイルが見つかりません。") }
        return (Dataset.uploadsDirectory(info.basePath).appendingPathComponent(stored), row["mimeType"] as? String ?? "application/octet-stream")
    }

    private func uploadContent(_ id: String) throws -> StoreResponse {
        let file = try uploadFile(id)
        guard let data = try? Data(contentsOf: file.url) else { throw StoreError(status: 404, message: "ファイルが見つかりません。") }
        return StoreResponse(status: 200, body: data, contentType: file.mimeType)
    }
}
