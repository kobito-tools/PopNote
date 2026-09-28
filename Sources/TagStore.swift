import Foundation

/// 両アプリ（Tomelet・PopNote!）で共有するタグ。正本は .kobito-tools/Tags/tags.json で、DBの tags / tag_categories はその写し。
/// Tomeletの scripts/tag-store.js と同じ規則で統合する。
/// - 同じIDは revision の大きい方。同じ revision なら、項目を決まった順に並べた文字列（UTF-16の並び）が大きい方。
/// - タグは完全削除せず、アーカイブだけにする。
/// - 同じ名前が2つあれば、IDの順で後になる方の名前に印を付け、revisionを上げる。
/// - 書く直前に tags.json の revision が変わっていれば、読み直して統合し直す。
enum TagStore {
    static let format = "kobito-tags"
    private static let maxAttempts = 5

    /// 1件のタグまたは分類。fieldsは tag-store.js の normalize〜 と同じ順に並べる。
    struct Record {
        let id: String
        var fields: [(key: String, value: Any?)]

        subscript(key: String) -> Any? {
            get { fields.first { $0.key == key }?.value ?? nil }
            set { if let index = fields.firstIndex(where: { $0.key == key }) { fields[index].value = newValue } }
        }
        var name: String { self["name"] as? String ?? "" }
        var revision: Int { self["revision"] as? Int ?? 1 }

        var canonical: String {
            fields.map { field -> String in
                switch field.value {
                case nil: return "\u{0}"
                case let value as Int: return String(value)
                case let value as String: return value
                default: return String(describing: field.value!)
                }
            }.joined(separator: "\u{1f}")
        }
        var json: [String: Any] { Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value ?? NSNull()) }) }
    }

    private struct Kind {
        let table: String
        /// (JSONのキー, DBの列, 種類)
        let columns: [(key: String, column: String, type: FieldType)]
    }
    private enum FieldType { case id, text(Int), trimmedText(Int), nullableText, positive, category }

    private static let categoryKind = Kind(table: "tag_categories", columns: [
        ("id", "id", .id), ("name", "name", .trimmedText(200)), ("description", "description", .text(1000)),
        ("displayOrder", "display_order", .positive), ("revision", "revision", .positive), ("deletedAt", "deleted_at", .nullableText),
    ])
    private static let tagKind = Kind(table: "tags", columns: [
        ("id", "id", .id), ("categoryId", "category_id", .category), ("name", "name", .trimmedText(200)), ("description", "description", .text(1000)),
        ("displayOrder", "display_order", .positive), ("revision", "revision", .positive), ("archivedAt", "archived_at", .nullableText), ("deletedAt", "deleted_at", .nullableText),
    ])

    private static func valid(_ raw: [String: Any]) -> Bool {
        guard let id = raw["id"] as? String, id.range(of: "^[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil,
              let name = raw["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    private static func normalize(_ raw: [String: Any], _ kind: Kind) -> Record {
        let fields: [(key: String, value: Any?)] = kind.columns.map { column in
            let value = raw[column.key]
            switch column.type {
            case .id: return (column.key, value as? String ?? "")
            case .text(let limit): return (column.key, String((value as? String ?? "").prefix(limit)))
            case .trimmedText(let limit): return (column.key, String((value as? String ?? "").prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines))
            case .nullableText: if let text = value as? String, !text.isEmpty { return (column.key, String(text.prefix(50))) } else { return (column.key, nil) }
            case .positive: if let number = value as? Int, number >= 1 { return (column.key, number) } else { return (column.key, 1) }
            case .category: if let text = value as? String, !text.isEmpty { return (column.key, text) } else { return (column.key, nil) }
            }
        }
        return Record(id: raw["id"] as? String ?? "", fields: fields)
    }

    private static func utf16Less(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

    private static func newer(_ a: Record?, _ b: Record) -> Record {
        guard let a else { return b }
        if a.revision != b.revision { return a.revision > b.revision ? a : b }
        return utf16Less(a.canonical, b.canonical) ? b : a
    }

    private static func mergeById(_ lists: [Record]...) -> [Record] {
        var merged: [String: Record] = [:]
        for list in lists { for record in list { merged[record.id] = newer(merged[record.id], record) } }
        return merged.values.sorted { utf16Less($0.id, $1.id) }
    }

    private static func resolveNameCollisions(_ records: [Record]) -> [Record] {
        var used = Set<String>()
        return records.map { record in
            guard used.contains(record.name) else { used.insert(record.name); return record }
            let tail = String(record.id.suffix(4))
            var name = "\(record.name) (\(tail))", suffix = 2
            while used.contains(name) { name = "\(record.name) (\(tail)-\(suffix))"; suffix += 1 }
            used.insert(name)
            var renamed = record
            renamed["name"] = name
            renamed["revision"] = record.revision + 1
            return renamed
        }
    }

    // MARK: - ファイル

    private struct FileState { let revision: Int; let categories: [Record]; let tags: [Record] }

    private static func readFile(_ url: URL) throws -> FileState {
        guard let data = try? Data(contentsOf: url) else { return FileState(revision: 0, categories: [], tags: []) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["format"] as? String == format else {
            throw StoreError(status: 422, message: "共有タグ（tags.json）を読み取れません。")
        }
        let records = { (key: String, kind: Kind) in ((object[key] as? [[String: Any]]) ?? []).filter(valid).map { normalize($0, kind) }.sorted { utf16Less($0.id, $1.id) } }
        return FileState(revision: object["revision"] as? Int ?? 0, categories: records("categories", categoryKind), tags: records("tags", tagKind))
    }

    // MARK: - DB

    private static func databaseRecords(_ database: SQLiteDatabase, _ kind: Kind) throws -> [Record] {
        let select = kind.columns.map { "\($0.column) AS \($0.key)" }.joined(separator: ", ")
        return try database.query("SELECT \(select) FROM \(kind.table)").map { normalize($0.filter { !($0.value is NSNull) }, kind) }
    }

    /// 変わった行だけを書き込む。名前の入れ替えでも一意制約に触れないよう、先に仮の名前へ退避する。
    private static func apply(_ database: SQLiteDatabase, _ kind: Kind, _ records: [Record], current: [Record]) throws -> Int {
        let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let changed = records.filter { byId[$0.id]?.canonical != $0.canonical }
        for record in changed where byId[record.id] != nil { try database.run("UPDATE \(kind.table) SET name = ? WHERE id = ?", "\u{0}\(UUID().uuidString)", record.id) }
        let columns = kind.columns.map(\.column)
        let sql = "INSERT INTO \(kind.table)(\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", "))) ON CONFLICT(id) DO UPDATE SET \(columns.filter { $0 != "id" }.map { "\($0) = excluded.\($0)" }.joined(separator: ", "))"
        for record in changed { try database.run(sql, values: record.fields.map(\.value)) }
        return changed.count
    }

    private static func same(_ a: [Record], _ b: [Record]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.canonical == $1.canonical }
    }

    /// tags.json とDBの写しを双方向に統合する。
    static func sync(_ database: SQLiteDatabase, basePath: String) throws {
        let url = Dataset.tagsFile(basePath)
        for _ in 0..<maxAttempts {
            let file = try readFile(url)
            let localCategories = try databaseRecords(database, categoryKind), localTags = try databaseRecords(database, tagKind)
            let categories = resolveNameCollisions(mergeById(localCategories, file.categories))
            let categoryIds = Set(categories.map(\.id))
            let tags = resolveNameCollisions(mergeById(localTags, file.tags).map { tag in
                // 分類が見つからないタグは「その他」へ入れる。
                guard let categoryId = tag["categoryId"] as? String, !categoryIds.contains(categoryId) else { return tag }
                var moved = tag
                moved["categoryId"] = categoryIds.contains("other") ? "other" : nil
                return moved
            })
            try database.transaction {
                _ = try apply(database, categoryKind, categories, current: localCategories)
                _ = try apply(database, tagKind, tags, current: localTags)
            }
            if same(categories, file.categories), same(tags, file.tags) { return }
            // 読んでから書くまでの間に本体が書き換えていたら、読み直して統合し直す。
            guard try readFile(url).revision == file.revision else { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Dataset.writeJSON(["format": format, "schemaVersion": 1, "revision": file.revision + 1, "updatedAt": Dataset.timestamp(),
                                   "categories": categories.map(\.json), "tags": tags.map(\.json)], to: url)
            return
        }
        throw StoreError(status: 409, message: "共有タグがTomeletで更新中です。少し待ってからもう一度お試しください。")
    }
}
