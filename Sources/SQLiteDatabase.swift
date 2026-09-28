import Foundation
import SQLite3

/// API向けのエラー。HTTPのステータスと、画面へ返すJSONの追加項目を持つ。
struct StoreError: Error {
    let status: Int
    let message: String
    var extra: [String: Any] = [:]

    static func badRequest(_ message: String) -> StoreError { StoreError(status: 400, message: message) }
    var json: [String: Any] { extra.merging(["error": message]) { _, new in new } }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// macOS標準のSQLiteを使う薄いラッパー。Tomelet（scripts/database/connection.js）と同じ設定で開く。
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw StoreError(status: 500, message: "データベースを開けませんでした: \(message)")
        }
        // 基準パスはクラウド同期フォルダに置かれることがあるため、-wal/-shmを残さないDELETEモードにする。
        try exec("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000; PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL;")
    }

    deinit { sqlite3_close_v2(handle) }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? lastError
            sqlite3_free(message)
            throw StoreError(status: 500, message: text)
        }
    }

    private func prepare(_ sql: String, _ parameters: [Any?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError(status: 500, message: lastError) }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, index)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as String: sqlite3_bind_text(statement, index, value, -1, transientDestructor)
            default: sqlite3_bind_text(statement, index, String(describing: value!), -1, transientDestructor)
            }
        }
        return statement
    }

    /// 行を列名つきの辞書で返す。NULLはNSNull（JSONではnull）になる。
    func query(_ sql: String, _ parameters: Any?...) throws -> [[String: Any]] { try rows(sql, parameters) }

    func first(_ sql: String, _ parameters: Any?...) throws -> [String: Any]? { try rows(sql, parameters).first }

    /// 条件の数が変わる検索など、引数を配列で渡したい場合に使う。
    func rows(_ sql: String, _ parameters: [Any?]) throws -> [[String: Any]] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: Any]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw constraintAware(lastError) }
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_NULL: row[name] = NSNull()
                default: row[name] = String(cString: sqlite3_column_text(statement, column))
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// 変更した行数を返す。
    @discardableResult
    func run(_ sql: String, _ parameters: Any?...) throws -> Int { try run(sql, values: parameters) }

    /// 引数の数が表によって変わる場合（共有タグの同期など）に使う。
    @discardableResult
    func run(_ sql: String, values parameters: [Any?]) throws -> Int {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw constraintAware(lastError) }
        return Int(sqlite3_changes(handle))
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // 本体（server.js）と同じく、一意制約は409、外部キーは400として扱う。
    private func constraintAware(_ message: String) -> StoreError {
        if message.contains("UNIQUE constraint failed") { return StoreError(status: 409, message: message) }
        if message.contains("FOREIGN KEY constraint failed") { return StoreError(status: 400, message: "存在しないタグ・添付が指定されています。") }
        return StoreError(status: 500, message: message)
    }
}
