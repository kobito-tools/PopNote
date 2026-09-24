import Cocoa

/// Tick Tock Tomeとの接続情報。トークンはPopNote!専用で、メモの読み書きだけを許可されている。
struct TickTockTomeConnection {
    let port: Int
    let token: String
}

enum TickTockTomeLinkError: LocalizedError {
    case notInstalled
    case outdated
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "PopNote!はTick Tock Tomeにメモを保存します。先にTick Tock Tomeをセットアップし、TickTockTome.appを一度起動してください。"
        case .outdated:
            return "Tick Tock TomeがPopNote!との連携に対応していません。Tick Tock Tomeを最新版に更新し、TickTockTome-Setup.commandを実行し直してください。"
        case .failed(let message):
            return message
        }
    }
}

/// インストール済みのTickTockTome.appを探し、そのNode.jsとプロジェクトでローカルサーバーを使う。
/// PopNote!はSQLiteや設定ファイルを直接読まず、Tick Tock Tomeの連携用入口（scripts/companion-connect.js）だけを呼ぶ。
final class TickTockTomeLink {
    static let mainAppBundleIdentifier = "local.ticktocktome.desktop"
    static let companionId = "popnote"

    private let projectRoot: URL
    private let nodeExecutable: URL

    init() throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.mainAppBundleIdentifier),
              let bundle = Bundle(url: appURL),
              let root = bundle.object(forInfoDictionaryKey: "TickTockTomeProjectRoot") as? String,
              let node = bundle.object(forInfoDictionaryKey: "TickTockTomeNodePath") as? String,
              FileManager.default.isExecutableFile(atPath: node),
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("scripts/launch.js").path)
        else { throw TickTockTomeLinkError.notInstalled }
        projectRoot = URL(fileURLWithPath: root, isDirectory: true)
        nodeExecutable = URL(fileURLWithPath: node)
        guard FileManager.default.fileExists(atPath: script("companion-connect.js").path) else { throw TickTockTomeLinkError.outdated }
    }

    static var isMainAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: mainAppBundleIdentifier).isEmpty
    }

    private func script(_ name: String) -> URL { projectRoot.appendingPathComponent("scripts/\(name)") }

    /// サーバーを本体ウィンドウなしで起動（起動済みなら何もしない）し、接続先を受け取る。
    func connect(completion: @escaping (Result<TickTockTomeConnection, Error>) -> Void) {
        let process = Process()
        let output = Pipe(), errors = Pipe()
        process.executableURL = nodeExecutable
        process.arguments = [script("companion-connect.js").path, Self.companionId]
        process.currentDirectoryURL = projectRoot
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { finished in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let result: Result<TickTockTomeConnection, Error>
            if finished.terminationStatus == 0,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let port = object["port"] as? Int, (1024...65535).contains(port),
               let token = object["token"] as? String, !token.isEmpty {
                result = .success(TickTockTomeConnection(port: port, token: token))
            } else {
                result = .failure(TickTockTomeLinkError.failed(message.isEmpty ? "Tick Tock Tomeに接続できませんでした。" : message))
            }
            DispatchQueue.main.async { completion(result) }
        }
        do { try process.run() } catch { completion(.failure(error)) }
    }

    /// 本体が開いていなければ、PopNote!が最後の利用者としてサーバーを止める。
    func stopServerIfUnused() {
        guard !Self.isMainAppRunning else { return }
        let process = Process()
        process.executableURL = nodeExecutable
        process.arguments = [script("stop.js").path]
        process.currentDirectoryURL = projectRoot
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { /* 既に終了済み */ }
    }
}
