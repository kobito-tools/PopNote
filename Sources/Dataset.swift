import CryptoKit
import Foundation

/// こびとツール共通の保存フォルダ（Tomeletの scripts/dataset.js と同じ規則）で保存先を扱う。
///
///   <保存先>/.kobito-tools/
///     dataset.json   format: "kobito-tools-dataset"・ID（Tomeletと共通）
///     PopNote/       lock.json・database/popnote.sqlite3・uploads/（PopNote!だけが書き込む）
///     Tomelet/       本体のデータ（PopNote!は触れない）
///     Tags/tags.json 両アプリで共有するタグ（TagStore.swift）
/// 保存先を後からTomeletの基準パスにすると、本体はIDを引き継ぎ、PopNote!のメモを表示できる。
struct DatasetInfo {
    let basePath: String
    let datasetId: String
    var key: String { Dataset.key(for: basePath) }
}

enum Dataset {
    static let rootName = ".kobito-tools"
    static let directoryName = "PopNote"
    static let legacyDirectoryName = ".TickTockTome"
    static let format = "kobito-tools-dataset"
    static let subdirectories = ["database", "uploads"]
    /// PopNote!の保存に必要なDB更新。
    static let requiredMigration = "015_memos.sql"

    // MARK: - 場所と識別子

    /// 選んだフォルダを本体と同じ規則で絶対パスにする（シンボリックリンクを解決し、.kobito-tools・その中のアプリのフォルダ・旧.TickTockTomeなら基準パスへ読み替える）。
    static func basePath(for url: URL) -> String {
        var resolved = url.standardizedFileURL.path
        if let real = realpath(resolved, nil) { resolved = String(cString: real); free(real) }
        let name = (resolved as NSString).lastPathComponent, parent = (resolved as NSString).deletingLastPathComponent
        if name == rootName || name == legacyDirectoryName { return parent }
        if (parent as NSString).lastPathComponent == rootName, ["Tomelet", directoryName, "Tags"].contains(name) { return (parent as NSString).deletingLastPathComponent }
        return resolved
    }

    /// 本体のdatasetKey()と同じく、基準パスのSHA-256の先頭16桁。
    static func key(for basePath: String) -> String {
        SHA256.hash(data: Data(basePath.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func root(_ basePath: String) -> URL { URL(fileURLWithPath: basePath, isDirectory: true).appendingPathComponent(rootName, isDirectory: true) }

    static func directory(_ basePath: String) -> URL { root(basePath).appendingPathComponent(directoryName, isDirectory: true) }

    static func uploadsDirectory(_ basePath: String) -> URL { directory(basePath).appendingPathComponent("uploads", isDirectory: true) }

    static func tagsFile(_ basePath: String) -> URL { root(basePath).appendingPathComponent("Tags", isDirectory: true).appendingPathComponent("tags.json") }

    static func databasePath(_ basePath: String) -> String { directory(basePath).appendingPathComponent("database").appendingPathComponent("popnote.sqlite3").path }

    private static func datasetFile(_ basePath: String) -> URL { root(basePath).appendingPathComponent("dataset.json") }

    private static func hasLegacyData(_ basePath: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: basePath).appendingPathComponent(legacyDirectoryName).appendingPathComponent("dataset.json").path)
    }

    /// 旧形式（本体とPopNote!が1つのDBを共有していた .TickTockTome）は、Tomeletが開くときに移行する。PopNote!は移行しない。
    private static let legacyError = StoreError(status: 409, message: "このフォルダには以前の形式（.TickTockTome）のデータがあります。Tomeletでこのフォルダを一度開くと、新しい形式（.kobito-tools）へ移行されます。", extra: ["legacyLayout": true])

    // MARK: - dataset.json

    static func validateId(_ value: String) throws -> String {
        let id = value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 60 else { throw StoreError.badRequest("IDは1〜60文字で入力してください。") }
        guard id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw StoreError.badRequest("IDに制御文字は使えません。") }
        return id
    }

    static func read(_ basePath: String) throws -> DatasetInfo? {
        guard let data = try? Data(contentsOf: datasetFile(basePath)) else {
            if hasLegacyData(basePath) { throw legacyError }
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["format"] as? String == format,
              let id = object["datasetId"] as? String else { throw StoreError(status: 422, message: "保存先のデータ（.kobito-tools/dataset.json）を読み取れません。") }
        return DatasetInfo(basePath: basePath, datasetId: try validateId(id))
    }

    /// .kobito-tools が無ければ一時フォルダで作ってから名前を変えて完成させる（途中で失敗しても中途半端なフォルダを残さない）。
    /// dataset.json の無い .kobito-tools（タグだけがあるなど）なら、dataset.json と PopNote/ だけを加える。
    static func create(_ basePath: String, datasetId: String) throws -> DatasetInfo {
        let id = try validateId(datasetId)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: basePath, isDirectory: &isDirectory), isDirectory.boolValue else { throw StoreError.badRequest("保存先はフォルダを指定してください。") }
        if hasLegacyData(basePath) { throw legacyError }
        guard !manager.fileExists(atPath: datasetFile(basePath).path) else { throw StoreError(status: 409, message: "このフォルダには既に保存先のデータがあります。") }
        let record: [String: Any] = ["format": format, "schemaVersion": 1, "datasetId": id, "createdAt": timestamp(), "revision": 1, "settings": [String: Any](), "legacyRoots": [String: Any]()]
        if manager.fileExists(atPath: root(basePath).path) {
            try ensureDirectories(basePath)
            try writeJSON(record, to: datasetFile(basePath))
            return DatasetInfo(basePath: basePath, datasetId: id)
        }
        let staging = URL(fileURLWithPath: basePath).appendingPathComponent("\(rootName)-creating-\(UUID().uuidString.lowercased())", isDirectory: true)
        do {
            for name in subdirectories { try manager.createDirectory(at: staging.appendingPathComponent(directoryName).appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            try writeJSON(record, to: staging.appendingPathComponent("dataset.json"))
            guard !manager.fileExists(atPath: root(basePath).path) else { throw StoreError(status: 409, message: "このフォルダには既に保存先のデータがあります。") }
            try manager.moveItem(at: staging, to: root(basePath))
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        return DatasetInfo(basePath: basePath, datasetId: id)
    }

    static func ensureDirectories(_ basePath: String) throws {
        for name in subdirectories { try FileManager.default.createDirectory(at: directory(basePath).appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }

    // MARK: - データベース

    /// 新しいDBは本体と同じDB更新（アプリに同梱したmigrations）で作る。既存のDBは更新せず、メモの表があるかだけを確かめる。
    /// 表の形を本体と同じにしておくと、本体は読み取り専用で開いてメモを表示できる。
    static func openDatabase(_ basePath: String, schemaDirectory: URL) throws -> SQLiteDatabase {
        try ensureDirectories(basePath)
        let database = try SQLiteDatabase(path: databasePath(basePath))
        try database.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL) STRICT;")
        let applied = Set(try database.query("SELECT version FROM schema_migrations").compactMap { $0["version"] as? String })
        if applied.contains(requiredMigration) { return database }
        guard applied.isEmpty, try database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name <> 'schema_migrations'").isEmpty else {
            throw StoreError(status: 409, message: "この保存先のメモのデータを読み取れません（DB更新の記録がありません）。")
        }
        let files = (try FileManager.default.contentsOfDirectory(atPath: schemaDirectory.path)).filter { $0.range(of: "^\\d+_[A-Za-z0-9_-]+\\.sql$", options: .regularExpression) != nil }.sorted()
        for file in files {
            let sql = try String(contentsOf: schemaDirectory.appendingPathComponent(file), encoding: .utf8)
            try database.transaction {
                try database.exec(sql)
                try database.run("INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", file, timestamp())
            }
        }
        return database
    }

    // MARK: - 共通

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func writeJSON(_ value: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// 同じ保存先を複数のPCのPopNote!で同時に書き込まないための使用中の印（.kobito-tools/PopNote/lock.json）。
/// 本体の印は Tomelet/ にあるため、本体とは干渉しない。
final class DatasetLock {
    enum State {
        case free
        case mine
        case heldOnThisMac
        case heldElsewhere(hostname: String)
    }

    static let staleInterval: TimeInterval = 120
    static let heartbeatInterval: TimeInterval = 30
    static let hostname: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        return gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : ProcessInfo.processInfo.hostName
    }()
    static let machineId: String = {
        if let saved = UserDefaults.standard.string(forKey: "MachineId") { return saved }
        let value = "popnote-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(value, forKey: "MachineId")
        return value
    }()

    let basePath: String
    private var startedAt: String?
    private var timer: Timer?
    private var file: URL { Dataset.directory(basePath).appendingPathComponent("lock.json") }

    init(basePath: String) { self.basePath = basePath }

    private func current() -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func state(now: Date = Date()) -> State {
        guard let lock = current() else { return .free }
        let pid = lock["pid"] as? Int ?? -1, host = lock["hostname"] as? String ?? ""
        if lock["app"] as? String == "popnote", host == Self.hostname, pid == Int(getpid()) { return .mine }
        let heartbeat = (lock["heartbeatAt"] as? String).flatMap(Dataset.parseTimestamp) ?? .distantPast
        guard now.timeIntervalSince(heartbeat) < Self.staleInterval else { return .free }
        if host == Self.hostname { return pid > 0 && (kill(pid_t(pid), 0) == 0 || errno == EPERM) ? .heldOnThisMac : .free }
        return .heldElsewhere(hostname: host.isEmpty ? "不明なPC" : host)
    }

    var isMine: Bool { if case .mine = state() { return true } else { return false } }

    /// 空いていれば使用中の印を置き、30秒ごとに更新する。印を失ったら（別のPCが期限切れの印を引き継いだなど）更新をやめ、次の保存で取り直す。
    func acquire() throws {
        switch state() {
        case .mine: break
        case .free: try write()
        case .heldOnThisMac: throw StoreError(status: 423, message: "この保存先はこのMacの別のPopNote!が使用中です。", extra: ["lockHolder": ["hostname": Self.hostname, "samePc": true]])
        case .heldElsewhere(let hostname): throw StoreError(status: 423, message: "この保存先は「\(hostname)」で使用中です。", extra: ["lockHolder": ["hostname": hostname, "samePc": false]])
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isMine { try? self.write() } else { self.stop() }
        }
    }

    private func write() throws {
        if startedAt == nil { startedAt = Dataset.timestamp() }
        let lock: [String: Any] = ["app": "popnote", "machineId": Self.machineId, "hostname": Self.hostname, "pid": Int(getpid()), "startedAt": startedAt!, "heartbeatAt": Dataset.timestamp()]
        try Dataset.writeJSON(lock, to: file)
    }

    private func stop() { timer?.invalidate(); timer = nil; startedAt = nil }

    func release() {
        let owned = isMine
        stop()
        if owned { try? FileManager.default.removeItem(at: file) }
    }
}
