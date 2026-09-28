import Cocoa
import WebKit

// PopNote! — 押したらポンッと出てくるクイックメモ。単独でも、Tomeletと連携しても使える。
// ランチャーやURL（popnote://new、popnote://open/<メモID>?dataset=<キー>）からすぐ書き始められる。
// ⌘N・⌘O・⌘T・⌘H・⌘A・⌘B・⌘U・⌘X・⌘Iはメニューへ割り当てず、画面側のショートカットへ渡す。
private let alwaysOnTopKey = "AlwaysOnTop"

@main
@MainActor
struct PopNoteApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = PopNoteDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
final class PopNoteDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var pageHandler: PageSchemeHandler!
    private var router: MemoRouter!
    private var pageLoaded = false
    // 起動していない状態でURLから呼ばれると、applicationDidFinishLaunchingより先にapplication(_:open:)が届く。
    // 画面ができるまでURLを預かり、起動処理の最後に開く。
    private var launched = false
    private var pendingURL: URL?
    private var terminating = false
    private var alwaysOnTopItem: NSMenuItem!
    private var signalSource: DispatchSourceSignal?

    private func pageURL(_ target: String) -> URL {
        var components = URLComponents(string: "\(PageSchemeHandler.origin)/index.html")!
        components.queryItems = [target == "new" ? URLQueryItem(name: "new", value: "1") : URLQueryItem(name: "id", value: target)]
        return components.url!
    }

    // MARK: - 起動

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        configureWindow()
        // ログアウトや終了シグナルでも、書きかけの内容を保存してから閉じる。
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        signalSource = source
        launched = true
        if let url = pendingURL {
            pendingURL = nil
            handle(url)
        } else {
            loadPage("new")
        }
    }

    private func loadPage(_ target: String) {
        webView.load(URLRequest(url: pageURL(target)))
        pageLoaded = true
    }

    // MARK: - URLとランチャーからの呼び出し

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last, url.scheme?.lowercased() == "popnote" else { return }
        guard launched else { pendingURL = url; return }
        handle(url)
    }

    private func handle(_ url: URL) {
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        let datasetKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dataset" }?.value
        if parts.first == "open", parts.count > 1, parts[1].range(of: "^memo-[0-9a-f-]{36}$", options: .regularExpression) != nil { open(parts[1], datasetKey: datasetKey) }
        else if parts.isEmpty || parts.first == "new" { open("new", datasetKey: nil) }
        else if !pageLoaded { loadPage("new") }
    }

    /// 本体のカレンダーなどから別の保存先のメモを開く場合は、先に保存先を合わせてから開く。
    private func open(_ target: String, datasetKey: String?) {
        showWindow()
        Task { @MainActor in
            await flushPage()
            if let datasetKey, router.current?.key != datasetKey {
                guard await router.switchToDataset(key: datasetKey) else {
                    if !pageLoaded { loadPage("new") }
                    let alert = NSAlert()
                    alert.messageText = "このメモの保存先が見つかりません"
                    alert.informativeText = "PopNote!の保存先に、Tomeletで開いている基準パスを選んでから、もう一度開いてください。"
                    alert.beginSheetModal(for: window) { _ in }
                    return
                }
                loadPage(target)
                return
            }
            // 起動直後はまだ画面を読み込んでいないので、目的のメモを最初の画面として開く。
            guard pageLoaded else { loadPage(target); return }
            let script = "if (window.PopNote) await window.PopNote.openTarget(target); else location.replace(url); return true;"
            _ = try? await webView.callAsyncJavaScript(script, arguments: ["target": target, "url": pageURL(target).absoluteString], in: nil, contentWorld: .page)
        }
    }

    private func flushPage() async {
        guard pageLoaded else { return }
        _ = try? await webView.callAsyncJavaScript("if (window.PopNote) await window.PopNote.flush(); return true;", arguments: [:], in: nil, contentWorld: .page)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: - 画面

    private func configureMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "PopNote!について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "PopNote!を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        // ⌘Xは取り消し線、⌘Aは添付に使うため、カットと全選択はショートカットなしで置く。
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        alwaysOnTopItem = windowMenu.addItem(withTitle: "常に手前に表示", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        alwaysOnTopItem.target = self
        windowItem.submenu = windowMenu
        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    private func configureWindow() {
        router = MemoRouter(schemaDirectory: Bundle.main.resourceURL!.appendingPathComponent("schema", isDirectory: true))
        pageHandler = PageSchemeHandler(webRoot: Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true), router: router)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.setURLSchemeHandler(pageHandler, forURLScheme: PageSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PopNote!"
        window.minSize = NSSize(width: 420, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("PopNoteWindow")
        applyAlwaysOnTop(UserDefaults.standard.bool(forKey: alwaysOnTopKey))
        showWindow()
    }

    @objc private func toggleAlwaysOnTop() {
        let enabled = !UserDefaults.standard.bool(forKey: alwaysOnTopKey)
        UserDefaults.standard.set(enabled, forKey: alwaysOnTopKey)
        applyAlwaysOnTop(enabled)
    }

    private func applyAlwaysOnTop(_ enabled: Bool) {
        window.level = enabled ? .floating : .normal
        window.collectionBehavior = enabled ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        alwaysOnTopItem?.state = enabled ? .on : .off
    }

    // MARK: - 終了

    // ⌘Qと同じく、ウィンドウを閉じたらアプリも終了する。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApplication.shared.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        terminating = true
        var replied = false
        let reply = { [weak self] in
            guard !replied else { return }
            replied = true
            // 使用中の印を外し、Tomeletがこの保存先をすぐ開けるようにする。
            self?.router.releaseLock()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        // 入力直後に閉じても、保存待ちの内容を書き込んでから終了する。
        Task { @MainActor in await flushPage(); reply() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { reply() }
        return .terminateLater
    }

    // MARK: - WebView

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if ["about", PageSchemeHandler.scheme].contains(url.scheme ?? "") { decisionHandler(.allow); return }
        if ["https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    // 添付画像の「開く」は、既定のブラウザで原寸表示する。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if url.scheme?.lowercased() == "https" { NSWorkspace.shared.open(url); return nil }
        let parts = url.pathComponents
        if url.scheme == PageSchemeHandler.scheme, parts.count == 6, parts[1] == "api", parts[3] == "uploads", parts[5] == "content" {
            Task { @MainActor in if let target = await router.externalUploadURL(parts[4]) { NSWorkspace.shared.open(target) } }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn) }
    }
}
