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
        let given = CommandLine.arguments.drop { $0 != "--self-test" }.dropFirst()
            .filter { $0.hasPrefix("http") }.compactMap(URL.init(string:))
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

        print("== tab playing sound")
        let audio = BrowserWindowController.open(url: nil, in: nil, isPrivate: false)
        audio.ensureWebView().loadHTMLString(soundPage, baseURL: URL(string: "https://example.com/"))
        try? await Task.sleep(for: .seconds(3))
        print("  audible: \(audio.isPlayingSound)")

        print("== loading \(sites.count) sites in tabs")
        var tabs: [BrowserWindowController] = []
        for url in sites {
            tabs.append(BrowserWindowController.open(url: url, in: audio.window, isPrivate: false))
        }
        await waitForLoads(tabs, timeout: 90)
        try? await Task.sleep(for: .seconds(5))
        for tab in tabs { print("  \(tab.webView == nil ? "asleep " : tab.webView!.isLoading ? "loading" : "loaded ") \(tab.currentURL?.host ?? "?")") }
        check(tabs.allSatisfy { $0.webView != nil }, "all tabs awake before the sleep test")
        let awakeMB = memoryMB()
        print("  memory with all \(tabs.count) tabs awake: \(awakeMB.total) MB (app \(awakeMB.app) MB + \(awakeMB.helpers) web processes \(awakeMB.web) MB)")

        print("== sleeping background tabs")
        let shown = tabs.last!
        check(shown.isShowing, "last opened tab is the visible one")
        let urlsBefore = tabs.map { $0.currentURL }
        check(audio.isPlayingSound, "tab playing sound is detected")
        let delegate = NSApp.delegate as! AppDelegate
        delegate.handleMemoryPressure(critical: false)
        check(tabs.allSatisfy { $0.webView != nil }, "memory warning leaves recently used tabs alone")
        delegate.handleMemoryPressure(critical: true)
        try? await Task.sleep(for: .seconds(8))
        let background = tabs.dropLast()
        let asleep = background.filter { $0.isAsleep }.count
        check(asleep == background.count, "\(asleep) of \(background.count) background tabs asleep")
        check(shown.webView != nil, "visible tab stays awake")
        check(audio.webView != nil, "background tab playing sound stays awake")
        let sleepMB = memoryMB()
        print("  memory after sleeping: \(sleepMB.total) MB (\(sleepMB.helpers) web processes)")
        check(sleepMB.total < awakeMB.total, "memory dropped by \(awakeMB.total - sleepMB.total) MB")

        print("== sound stops")
        _ = try? await audio.webView?.evaluateJavaScript("document.querySelector('audio').pause()")
        try? await Task.sleep(for: .seconds(1))
        check(!audio.isPlayingSound, "pausing is detected")
        audio.sleepIfIdle()
        check(audio.isAsleep, "silent tab can sleep")

        print("== waking a tab")
        let first = tabs[0]
        first.window?.tabGroup?.selectedWindow = first.window
        first.ensureWebView()
        await waitForLoads([first], timeout: 30)
        check(first.webView != nil && !first.isAsleep, "tab woke up")
        check(first.currentURL?.host == urlsBefore[0]?.host, "woke on the same page (\(first.currentURL?.host ?? "nil"))")
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            await snapshot(first, to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }

        print("== private window")
        let priv = BrowserWindowController.open(url: URL(string: "https://example.org")!, in: nil, isPrivate: true)
        await waitForLoads([priv], timeout: 20)
        check(priv.webView?.configuration.websiteDataStore.isPersistent == false, "private tab uses non-persistent storage")
        check(!Store.shared.history.contains { $0.url.contains("example.org") }, "private visit not in history")
        check(Store.shared.history.contains { $0.url.contains("wikipedia.org") }, "normal visit is in history")
    }

    /// A page that loops a generated, unmuted (silent-sample) WAV through an <audio> element.
    private static let soundPage = """
    <html><body><audio loop></audio><script>
    const rate = 8000, samples = rate * 2, buf = new ArrayBuffer(44 + samples * 2), v = new DataView(buf);
    const str = (o, s) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
    str(0, 'RIFF'); v.setUint32(4, 36 + samples * 2, true); str(8, 'WAVEfmt ');
    v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true);
    v.setUint16(34, 16, true); str(36, 'data'); v.setUint32(40, samples * 2, true);
    const a = document.querySelector('audio');
    a.src = URL.createObjectURL(new Blob([buf], { type: 'audio/wav' }));
    a.play();
    </script></body></html>
    """

    /// Renders a tab's whole window (toolbar, tab bar and page) to a PNG without putting it on screen.
    private static func snapshot(_ tab: BrowserWindowController, to file: URL) async {
        guard let window = tab.window, let frameView = window.contentView?.superview,
              let webView = tab.webView else { return }
        try? await Task.sleep(for: .seconds(2))
        let page = try? await webView.takeSnapshot(configuration: nil)
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        let output = NSImage(size: frameView.bounds.size)
        output.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        if let page {
            let rect = webView.convert(webView.bounds, to: frameView)
            page.draw(in: frameView.isFlipped
                      ? NSRect(x: rect.minX, y: frameView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
                      : rect)
        }
        output.unlockFocus()
        if let tiff = output.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: file)
            print("  snapshot written to \(file.path)")
        }
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
