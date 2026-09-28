import Cocoa

/// 保存先の管理と、API要求の処理。
/// メモは常に PopNote! が保存先の .kobito-tools/PopNote/ へ直接保存する（本体の起動状態には左右されない）。
/// 保存先を Tomelet の基準パスにすると、本体は「本アプリでも表示する」設定のときにメモを読み取って表示する。
@MainActor
final class MemoRouter {
    private struct SavedDestination: Codable { let path: String; var datasetId: String }

    private let schemaDirectory: URL
    private let link: TickTockTomeLink?
    private let storeQueue = DispatchQueue(label: "io.github.kobito-tools.popnote.store")
    private(set) var current: DatasetInfo?
    private var lock: DatasetLock?
    private var recent: [SavedDestination]
    /// 保存先が変わったときに画面を読み直すため、アプリ側へ知らせる。
    var onDestinationChanged: (() -> Void)?

    init(schemaDirectory: URL) {
        self.schemaDirectory = schemaDirectory
        link = TickTockTomeLink()
        recent = (UserDefaults.standard.data(forKey: "Destinations").flatMap { try? JSONDecoder().decode([SavedDestination].self, from: $0) }) ?? []
        if let path = UserDefaults.standard.string(forKey: "CurrentDestination"), let info = try? Dataset.read(path) { current = info }
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(recent), forKey: "Destinations")
        UserDefaults.standard.set(current?.basePath, forKey: "CurrentDestination")
    }

    func releaseLock() { lock?.release(); lock = nil }

    // MARK: - 振り分け

    func handle(_ request: StoreRequest) async -> StoreResponse {
        do {
            switch (request.method, request.route) {
            case ("GET", "destinations"): return .json(200, await destinations())
            case ("POST", "destinations:choose"): return .json(200, try await chooseFolder())
            case ("POST", "destinations:select"): return .json(200, try await select(request.json()))
            case ("POST", "destinations:forget"): return .json(200, await forget(try request.json()["path"] as? String ?? ""))
            case ("POST", "files:pick"): return try await pickFile()
            case ("POST", "files:open"): try openFile(request.json()["relativePath"] as? String ?? ""); return .json(200, ["ok": true])
            default: return try await data(request)
            }
        } catch { return .error(error) }
    }

    private func data(_ request: StoreRequest) async throws -> StoreResponse {
        guard let current else { throw StoreError(status: 428, message: "メモの保存先を選んでください。", extra: ["destinationRequired": true]) }
        try ensureLock(current)
        let store = LocalMemoStore(info: current, schemaDirectory: schemaDirectory)
        return await withCheckedContinuation { continuation in storeQueue.async { continuation.resume(returning: store.handle(request)) } }
    }

    private func ensureLock(_ info: DatasetInfo) throws {
        if lock?.basePath != info.basePath { releaseLock(); lock = DatasetLock(basePath: info.basePath) }
        guard let lock, !lock.isMine else { return }
        try lock.acquire()
    }

    // MARK: - 保存先

    private func describe(_ path: String, datasetId: String?) -> [String: Any] {
        let exists = FileManager.default.fileExists(atPath: Dataset.root(path).appendingPathComponent("dataset.json").path)
        return ["path": path, "name": (path as NSString).lastPathComponent, "id": datasetId ?? NSNull(), "key": Dataset.key(for: path), "available": exists, "current": current?.basePath == path]
    }

    private func destinations() async -> [String: Any] {
        var tickTockTome: [String: Any] = ["installed": link != nil, "running": TickTockTomeLink.isRunning, "current": NSNull()]
        if let opened = await link?.currentDataset() {
            tickTockTome["current"] = ["id": opened.id, "key": opened.key, "basePath": opened.basePath, "name": (opened.basePath as NSString).lastPathComponent]
        }
        // "ticktocktome" は、保存先をTomeletも基準パスとして開いている（本体でも表示できる）ことを表す。保存は常に直接行う。
        let mode: String
        if let current, let opened = await link?.currentDataset(), opened.key == current.key { mode = "ticktocktome" } else { mode = current == nil ? "none" : "local" }
        return [
            "current": current.map { describe($0.basePath, datasetId: $0.datasetId) } ?? NSNull(),
            "recent": recent.map { describe($0.path, datasetId: $0.datasetId) },
            "tickTockTome": tickTockTome,
            "mode": mode,
        ]
    }

    /// フォルダを選ぶ画面を開く。選んだだけでは保存先を変えない（新しいフォルダならIDを決めてから作る）。
    private func chooseFolder() async throws -> [String: Any] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "保存先にする"
        panel.message = "メモを保存するフォルダを選んでください。Tomeletの基準パスを選ぶと、本体のカレンダーにも表示できます。"
        if let current { panel.directoryURL = URL(fileURLWithPath: current.basePath) }
        guard await panel.begin() == .OK, let url = panel.url else { return ["cancelled": true] }
        let path = Dataset.basePath(for: url)
        let existing = try Dataset.read(path)
        return ["path": path, "name": (path as NSString).lastPathComponent, "existing": existing.map { ["id": $0.datasetId] } ?? NSNull(), "suggestedId": String((path as NSString).lastPathComponent.prefix(60))]
    }

    /// 保存先を切り替える。.kobito-tools/dataset.json が無ければ、指定されたIDで作る（あれば本体と同じIDを使う）。
    private func select(_ body: [String: Any]) async throws -> [String: Any] {
        guard let requested = body["path"] as? String, requested.hasPrefix("/") else { throw StoreError.badRequest("保存先のフォルダを指定してください。") }
        let path = Dataset.basePath(for: URL(fileURLWithPath: requested))
        let info = try Dataset.read(path) ?? Dataset.create(path, datasetId: body["datasetId"] as? String ?? "")
        try switchTo(info)
        return await destinations()
    }

    private func switchTo(_ info: DatasetInfo) throws {
        if current?.basePath != info.basePath { releaseLock() }
        current = info
        recent.removeAll { $0.path == info.basePath }
        recent.insert(SavedDestination(path: info.basePath, datasetId: info.datasetId), at: 0)
        recent = Array(recent.prefix(20))
        persist()
    }

    private func forget(_ path: String) async -> [String: Any] {
        if current?.basePath != path { recent.removeAll { $0.path == path }; persist() }
        return await destinations()
    }

    /// popnote://open/<メモID>?dataset=<キー> で、別の保存先のメモを開く場合に保存先を合わせる。
    func switchToDataset(key: String) async -> Bool {
        if current?.key == key { return true }
        if let saved = recent.first(where: { Dataset.key(for: $0.path) == key }), let info = try? Dataset.read(saved.path) { try? switchTo(info); onDestinationChanged?(); return true }
        if let opened = await link?.currentDataset(), opened.key == key, let info = try? Dataset.read(opened.basePath) { try? switchTo(info); onDestinationChanged?(); return true }
        return false
    }

    // MARK: - ファイル添付

    private func inside(_ url: URL, base: String) -> String? {
        let target = Dataset.basePath(for: url)
        guard target.hasPrefix(base + "/") else { return nil }
        return String(target.dropFirst(base.count + 1))
    }

    /// 保存先フォルダの中からファイルを選び、保存先からの相対パスで登録する。
    private func pickFile() async throws -> StoreResponse {
        guard let current else { throw StoreError(status: 428, message: "メモの保存先を選んでください。", extra: ["destinationRequired": true]) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: current.basePath)
        panel.message = "「\(current.datasetId)」のフォルダ内から添付するファイルを選んでください。"
        guard await panel.begin() == .OK, let url = panel.url else { return .json(200, ["cancelled": true]) }
        guard let relative = inside(url, base: current.basePath), !relative.hasPrefix(Dataset.rootName + "/"), !relative.hasPrefix(Dataset.legacyDirectoryName + "/") else {
            throw StoreError.badRequest("保存先フォルダ（\(current.datasetId)）の中のファイルを選んでください。")
        }
        let body = try JSONSerialization.data(withJSONObject: ["relativePath": relative])
        return try await data(StoreRequest(method: "POST", route: "files:reference", query: [:], body: body))
    }

    private func openFile(_ relativePath: String) throws {
        guard let current else { throw StoreError(status: 428, message: "メモの保存先を選んでください。") }
        let url = URL(fileURLWithPath: current.basePath).appendingPathComponent(relativePath)
        guard !relativePath.split(separator: "/").contains(".."), inside(url, base: current.basePath) != nil, FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError(status: 404, message: "ファイルが見つかりません。保存先フォルダの中で移動・削除されていないか確認してください。")
        }
        NSWorkspace.shared.open(url)
    }

    /// 添付画像を原寸で開くための場所（保存先の PopNote/uploads/ のファイル）。
    func externalUploadURL(_ id: String) async -> URL? {
        guard let current else { return nil }
        return try? LocalMemoStore(info: current, schemaDirectory: schemaDirectory).uploadFile(id).url
    }
}
