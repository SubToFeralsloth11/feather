import AppKit
import WebKit

/// Off-screen end-to-end test: `Feather --self-test [urls…]`.
///
/// Runs with no Dock icon, invisible windows and a throwaway data folder, so it never shows up on
/// screen or touches your real history/session. Loads real sites in tabs, measures memory, puts
/// background tabs to sleep, measures again, wakes one, and checks ad blocking. Exits 0 on pass.
@MainActor
enum SelfTest {
    static let isActive = CommandLine.arguments.contains("--self-test")

    private static var failures: [String] = []
    private static let startPIDs = webKitPIDs()

    static func check(_ condition: Bool, _ message: String) {
        print((condition ? "  ok   " : "  FAIL ") + message)
        if !condition { failures.append(message) }
    }

    /// Hides a window from the screen without changing how AppKit treats it.
    static func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    }

    static func run() {
        _ = startPIDs
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            await body()
            print(failures.isEmpty ? "SELF-TEST PASS" : "SELF-TEST FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    private static func body() async {
        let given = CommandLine.arguments.drop { $0 != "--self-test" }.dropFirst().compactMap(URL.init(string:))
        let sites = given.isEmpty ? [
            "https://en.wikipedia.org/wiki/Web_browser", "https://github.com/", "https://www.youtube.com/",
            "https://www.reddit.com/", "https://edition.cnn.com/",
        ].compactMap(URL.init(string:)) : Array(given)

        print("== address bar")
        check(Settings.url(fromInput: "example.com")?.absoluteString == "https://example.com", "domain → https")
        check(Settings.url(fromInput: "localhost:3000")?.absoluteString == "http://localhost:3000", "localhost → http")
        check(Settings.url(fromInput: "192.168.1.1/admin")?.absoluteString == "http://192.168.1.1/admin", "IP → http")
        check(Settings.url(fromInput: "how tall is everest")?.host?.contains(Settings.searchEngine == .google ? "google" : "") == true, "words → search")
        check(Settings.url(fromInput: "https://a.b/c?d=1")?.absoluteString == "https://a.b/c?d=1", "full URL kept")

        print("== ad blocking")
        check(await adRequestBlocked(), "request to doubleclick.net from another site is blocked")

        print("== loading \(sites.count) sites in tabs")
        var tabs: [BrowserWindowController] = []
        for url in sites {
            tabs.append(BrowserWindowController.open(url: url, in: tabs.first?.window, isPrivate: false))
        }
        await waitForLoads(tabs, timeout: 45)
        try? await Task.sleep(for: .seconds(5))
        for tab in tabs { print("  \(tab.webView?.isLoading == false ? "loaded " : "loading") \(tab.currentURL?.host ?? "?")") }
        let awakeMB = memoryMB()
        print("  memory with all \(tabs.count) tabs awake: \(awakeMB.total) MB (app \(awakeMB.app) MB + \(awakeMB.helpers) web processes \(awakeMB.web) MB)")

        print("== sleeping background tabs")
        let shown = tabs.last!
        check(shown.isShowing, "last opened tab is the visible one")
        let urlsBefore = tabs.map { $0.currentURL }
        (NSApp.delegate as? AppDelegate)?.sleepBackgroundTabs(nil)
        try? await Task.sleep(for: .seconds(8))
        let asleep = tabs.filter { $0.isAsleep }.count
        check(asleep == tabs.count - 1, "\(asleep) of \(tabs.count - 1) background tabs asleep")
        check(shown.webView != nil, "visible tab stays awake")
        let sleepMB = memoryMB()
        print("  memory after sleeping: \(sleepMB.total) MB (\(sleepMB.helpers) web processes)")
        check(sleepMB.total < awakeMB.total, "memory dropped by \(awakeMB.total - sleepMB.total) MB")

        print("== waking a tab")
        let first = tabs[0]
        first.window?.tabGroup?.selectedWindow = first.window
        first.ensureWebView()
        await waitForLoads([first], timeout: 30)
        check(first.webView != nil && !first.isAsleep, "tab woke up")
        check(first.currentURL?.host == urlsBefore[0]?.host, "woke on the same page (\(first.currentURL?.host ?? "nil"))")

        print("== private window")
        let priv = BrowserWindowController.open(url: URL(string: "https://example.com")!, in: nil, isPrivate: true)
        await waitForLoads([priv], timeout: 20)
        check(priv.webView?.configuration.websiteDataStore.isPersistent == false, "private tab uses non-persistent storage")
        check(!Store.shared.history.contains { $0.url.contains("example.com") }, "private visit not in history")
        check(Store.shared.history.contains { $0.url.contains("wikipedia.org") }, "normal visit is in history")
    }

    private static func waitForLoads(_ tabs: [BrowserWindowController], timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if tabs.allSatisfy({ $0.webView.map { !$0.isLoading } ?? true }) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Loads a page "from" example.com that fetches an ad URL and reports whether it got through.
    private static func adRequestBlocked() async -> Bool {
        let webView = WKWebView(frame: .zero, configuration: Engine.makeConfiguration(isPrivate: true))
        webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://example.com/"))
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading && Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
        let script = """
        try { await fetch('https://securepubads.g.doubleclick.net/tag/js/gpt.js', {mode: 'no-cors'}); return 'loaded'; }
        catch (e) { return 'blocked'; }
        """
        let result = try? await webView.callAsyncJavaScript(script, contentWorld: .page)
        return (result as? String) == "blocked"
    }

    // MARK: Memory

    private static func processes() -> [(pid: Int32, rssKB: Int, command: String)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let rss = Int(parts[1]) else { return nil }
            return (pid, rss, String(parts[2]))
        }
    }

    private static func webKitPIDs() -> Set<Int32> {
        Set(processes().filter { $0.command.contains("com.apple.WebKit") }.map(\.pid))
    }

    /// Resident memory of this app plus the WebKit helper processes started since launch.
    private static func memoryMB() -> (total: Int, app: Int, web: Int, helpers: Int) {
        let all = processes()
        let me = ProcessInfo.processInfo.processIdentifier
        let app = all.first { $0.pid == me }?.rssKB ?? 0
        let web = all.filter { $0.command.contains("com.apple.WebKit") && !startPIDs.contains($0.pid) }
        let webKB = web.reduce(0) { $0 + $1.rssKB }
        return ((app + webKB) / 1024, app / 1024, webKB / 1024, web.count)
    }
}
