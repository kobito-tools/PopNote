import Cocoa
import WebKit

// PopNote! — 押したらポンッと出てくる、Tick Tock Tome連携のクイックメモ。
// ランチャーやURL（popnote://new、popnote://open/<メモID>）からすぐ書き始められる。
// ⌘N・⌘O・⌘T・⌘H・⌘A・⌘B・⌘U・⌘X・⌘Iはメニューへ割り当てず、画面側のショートカットへ渡す。
private let alwaysOnTopKey = "AlwaysOnTop"

@main
struct PopNoteApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = PopNoteDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

final class PopNoteDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var pageHandler: PageSchemeHandler!
    private var link: TickTockTomeLink?
    private var pendingTarget = "new"
    private var connected = false
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
        do {
            let link = try TickTockTomeLink()
            self.link = link
            link.connect { [weak self] result in
                guard let self, !self.terminating else { return }
                switch result {
                case .success(let connection):
                    self.pageHandler.connect(connection)
                    self.connected = true
                    self.webView.load(URLRequest(url: self.pageURL(self.pendingTarget)))
                case .failure(let error):
                    self.fail("Tick Tock Tomeに接続できませんでした", error.localizedDescription)
                }
            }
        } catch {
            fail("Tick Tock Tomeが見つかりません", error.localizedDescription)
        }
    }

    private func fail(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
        terminating = true
        NSApplication.shared.terminate(nil)
    }

    // MARK: - URLとランチャーからの呼び出し

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last, url.scheme?.lowercased() == "popnote" else { return }
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        if parts.first == "open", parts.count > 1, parts[1].range(of: "^memo-[0-9a-f-]{36}$", options: .regularExpression) != nil { open(parts[1]) }
        else if parts.isEmpty || parts.first == "new" { open("new") }
    }

    private func open(_ target: String) {
        showWindow()
        guard connected else { pendingTarget = target; return }
        let script = "if (window.PopNote) await window.PopNote.openTarget(target); else location.replace(url); return true;"
        webView.callAsyncJavaScript(script, arguments: ["target": target, "url": pageURL(target).absoluteString], in: nil, in: .page) { _ in }
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
        pageHandler = PageSchemeHandler(webRoot: Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true))
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
        webView.loadHTMLString("<!doctype html><meta charset=utf-8><body style=\"font:13px -apple-system,sans-serif;color:#8a8580;display:grid;place-items:center;height:100vh;margin:0\">Tick Tock Tomeに接続しています…</body>", baseURL: nil)
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
        if terminating && !connected { return .terminateNow }
        if terminating { return .terminateLater }
        terminating = true
        var replied = false
        let reply = { [weak self] in
            guard !replied else { return }
            replied = true
            if self?.connected == true { self?.link?.stopServerIfUnused() }
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        // 入力直後に閉じても、保存待ちの内容を書き込んでから終了する。
        webView.callAsyncJavaScript("if (window.PopNote) await window.PopNote.flush(); return true;", arguments: [:], in: nil, in: .page) { _ in reply() }
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
        if let url = navigationAction.request.url {
            if let target = pageHandler.serverURL(for: url) { NSWorkspace.shared.open(target) }
            else if url.scheme?.lowercased() == "https" { NSWorkspace.shared.open(url) }
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
