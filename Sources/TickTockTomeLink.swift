import Cocoa

/// Tomeletとの接続情報。トークンはPopNote!専用。
struct TickTockTomeConnection {
    let port: Int
    let token: String
}

/// Tomeletが今開いている基準パス。
struct TickTockTomeDataset {
    let id: String
    let key: String
    let basePath: String
}

/// Tomeletが今開いている基準パスを調べる（保存先の候補として示すため）。
/// メモは常にPopNote!が .kobito-tools/PopNote/ へ直接保存し、本体へは送らない。
final class TickTockTomeLink {
    static let mainAppBundleIdentifier = "local.ticktocktome.desktop"
    static let companionId = "popnote"

    private let projectRoot: URL
    private let nodeExecutable: URL
    private var connection: TickTockTomeConnection?
    private var cached: (dataset: TickTockTomeDataset?, at: Date)?
    private let session = URLSession(configuration: .ephemeral)

    /// インストール済みのTomelet.appを探す。見つからなければnil（PopNote!単独で動く）。
    init?() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.mainAppBundleIdentifier),
              let bundle = Bundle(url: appURL),
              let root = bundle.object(forInfoDictionaryKey: "TickTockTomeProjectRoot") as? String,
              let node = bundle.object(forInfoDictionaryKey: "TickTockTomeNodePath") as? String,
              FileManager.default.isExecutableFile(atPath: node),
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("scripts/companion-connect.js").path)
        else { return nil }
        projectRoot = URL(fileURLWithPath: root, isDirectory: true)
        nodeExecutable = URL(fileURLWithPath: node)
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: mainAppBundleIdentifier).isEmpty
    }

    /// 専用トークンを受け取る（初回は本体のintegrations.jsonへ登録される）。本体のサーバーは起動しない。
    private func connect() async throws -> TickTockTomeConnection {
        if let connection { return connection }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = nodeExecutable
        process.arguments = [projectRoot.appendingPathComponent("scripts/companion-connect.js").path, Self.companionId, "--no-launch"]
        process.currentDirectoryURL = projectRoot
        process.standardOutput = output
        process.standardError = errors
        let result: TickTockTomeConnection = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if finished.terminationStatus == 0, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let port = object["port"] as? Int, (1024...65535).contains(port), let token = object["token"] as? String, !token.isEmpty {
                    continuation.resume(returning: TickTockTomeConnection(port: port, token: token))
                } else {
                    continuation.resume(throwing: StoreError(status: 502, message: message.isEmpty ? "Tomeletに接続できませんでした。" : message))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        connection = result
        return result
    }

    /// 本体が今開いている基準パス。本体が閉じている・基準パスが未設定なら nil。数秒だけ結果を使い回す。
    func currentDataset() async -> TickTockTomeDataset? {
        guard Self.isRunning else { cached = nil; return nil }
        if let cached, Date().timeIntervalSince(cached.at) < 3 { return cached.dataset }
        var dataset: TickTockTomeDataset? = nil
        if let object = try? await context(), let info = object["dataset"] as? [String: Any],
           let id = info["id"] as? String, let key = info["key"] as? String, let basePath = info["basePath"] as? String {
            dataset = TickTockTomeDataset(id: id, key: key, basePath: basePath)
        }
        cached = (dataset, Date())
        return dataset
    }

    private func context() async throws -> [String: Any]? {
        let connection = try await connect()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(connection.port)/api/v1/integrations/memo/context")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
