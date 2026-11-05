import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var sleepTimer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var keyMonitor: Any?
    private let historyMenu = NSMenu(title: "History")
    private let bookmarksMenu = NSMenu(title: "Bookmarks")
    private var settingsItems: [NSMenuItem] = []
    private var pendingOpenURLs: [URL] = []
    private var ready = false

    private var current: BrowserWindowController? {
        (NSApp.keyWindow?.windowController ?? NSApp.mainWindow?.windowController) as? BrowserWindowController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        buildMenus()
        installKeyMonitor()
        startMemoryManagement()
        Engine.prepare { [weak self] in
            guard let self else { return }
            self.ready = true
            if SelfTest.isActive { SelfTest.run(); return }
            self.restoreSession()
            for url in self.pendingOpenURLs { self.openExternal(url) }
            self.pendingOpenURLs.removeAll()
            if BrowserWindowController.all.isEmpty { self.newWindow(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Links opened from other apps (when Feather is the default browser).
    func application(_ application: NSApplication, open urls: [URL]) {
        if ready { urls.forEach(openExternal) } else { pendingOpenURLs.append(contentsOf: urls) }
    }

    private func openExternal(_ url: URL) {
        let host = BrowserWindowController.all.last(where: { !$0.isPrivate })?.window
        BrowserWindowController.open(url: url, in: host, isPrivate: false)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Memory management

    private func startMemoryManagement() {
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { self.sleepIdleTabs() }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { self.sleepBackgroundTabs(nil) }
        }
        source.resume()
        pressureSource = source
    }

    private var lastSessionSave = Date.distantPast

    private func sleepIdleTabs() {
        let now = Date()
        let limit = TimeInterval(Settings.sleepAfterMinutes * 60)
        for tab in BrowserWindowController.all where tab.webView != nil {
            if tab.isShowing { continue }
            if limit > 0 && now.timeIntervalSince(tab.lastActive) > limit { tab.sleepIfIdle() }
        }
        if now.timeIntervalSince(lastSessionSave) > 60 {
            lastSessionSave = now
            saveSession()
        }
    }

    @objc func sleepBackgroundTabs(_ sender: Any?) {
        for tab in BrowserWindowController.all where tab.webView != nil && !tab.isShowing {
            tab.sleepIfIdle()
        }
    }

    // MARK: Session

    private func saveSession() {
        var groups: [[BrowserWindowController]] = []
        var seen = Set<ObjectIdentifier>()
        for tab in BrowserWindowController.all where !tab.isPrivate {
            guard let window = tab.window, !seen.contains(ObjectIdentifier(window)) else { continue }
            let windows = window.tabbedWindows ?? [window]
            let tabs = windows.compactMap { $0.windowController as? BrowserWindowController }
            tabs.forEach { if let w = $0.window { seen.insert(ObjectIdentifier(w)) } }
            groups.append(tabs)
        }
        let session = groups.compactMap { tabs -> SessionWindow? in
            let entries = tabs.compactMap { tab in
                tab.currentURL.map { SessionTab(title: tab.currentTitle, url: $0.absoluteString) }
            }
            guard !entries.isEmpty else { return nil }
            let selectedTab = tabs.first { $0.window?.tabGroup?.selectedWindow === $0.window }
            let selected = selectedTab.flatMap { tab in entries.firstIndex { $0.url == tab.currentURL?.absoluteString } } ?? 0
            return SessionWindow(tabs: entries, selected: selected, frame: tabs.first?.window.map { NSStringFromRect($0.frame) })
        }
        Store.shared.saveSession(session)
    }

    private func restoreSession() {
        for saved in Store.shared.loadSession() {
            var host: NSWindow?
            var selectedTab: BrowserWindowController?
            for (index, entry) in saved.tabs.enumerated() {
                guard let url = URL(string: entry.url) else { continue }
                let tab = BrowserWindowController.open(url: url, title: entry.title, in: host, isPrivate: false,
                                                       select: false, lazy: true)
                if host == nil {
                    host = tab.window
                    if let frame = saved.frame { tab.window?.setFrame(NSRectFromString(frame), display: false) }
                }
                if index == saved.selected { selectedTab = tab }
            }
            (selectedTab ?? BrowserWindowController.all.last)?.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Actions

    @objc func newWindow(_ sender: Any?) {
        BrowserWindowController.open(url: nil, in: nil, isPrivate: false)
    }

    @objc func newPrivateWindow(_ sender: Any?) {
        BrowserWindowController.open(url: nil, in: nil, isPrivate: true)
    }

    /// Fallback for ⌘T when no browser window is open.
    @objc func newWindowForTab(_ sender: Any?) {
        newWindow(sender)
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        BrowserWindowController.reopenClosedTab(in: nil)
    }

    @objc func openMenuURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let current { current.load(url) } else { BrowserWindowController.open(url: url, in: nil, isPrivate: false) }
    }

    @objc func toggleBlockAds(_ sender: NSMenuItem) {
        Settings.blockAds.toggle()
        Engine.applyBlocking()
        refreshSettingsMenu()
    }

    @objc func toggleAutoplay(_ sender: NSMenuItem) {
        Settings.blockAutoplay.toggle()
        refreshSettingsMenu()
    }

    @objc func setSleepAfter(_ sender: NSMenuItem) {
        Settings.sleepAfterMinutes = sender.tag
        refreshSettingsMenu()
    }

    @objc func setSearchEngine(_ sender: NSMenuItem) {
        if let engine = sender.representedObject as? String, let value = SearchEngine(rawValue: engine) {
            Settings.searchEngine = value
        }
        refreshSettingsMenu()
    }

    @objc func clearHistory(_ sender: Any?) {
        Store.shared.clearHistory()
    }

    @objc func clearBrowsingData(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear browsing data?"
        alert.informativeText = "Removes history, cookies, cache and site data. You will be signed out of websites."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Store.shared.clearHistory()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: .distantPast) {}
    }

    @objc func showMemoryReport(_ sender: Any?) {
        let tabs = BrowserWindowController.all
        let awake = tabs.filter { $0.webView != nil }.count
        let alert = NSAlert()
        alert.messageText = "\(awake) of \(tabs.count) tabs are using memory"
        alert.informativeText = """
        The other \(tabs.count - awake) are asleep or empty and use almost nothing.
        Background tabs sleep after \(Settings.sleepAfterMinutes == 0 ? "never (disabled)" : "\(Settings.sleepAfterMinutes) min"), \
        and right away when the Mac runs low on memory.
        """
        alert.runModal()
    }

    // MARK: Keyboard shortcuts not expressible as menu items

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { self.handleKey(event) ? nil : event }
        }
    }

    /// ⌘1–⌘8 pick a tab, ⌘9 the last tab, ⌃Tab / ⌃⇧Tab cycle tabs.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window.windowController is BrowserWindowController else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let tabs = window.tabbedWindows ?? [window]
        if flags == .command, let chars = event.charactersIgnoringModifiers, let digit = Int(chars), digit >= 1 {
            let target = digit == 9 ? tabs.last : (digit <= tabs.count ? tabs[digit - 1] : nil)
            target?.makeKeyAndOrderFront(nil)
            return target != nil
        }
        if event.keyCode == 48, flags.contains(.control) {
            guard tabs.count > 1, let index = tabs.firstIndex(of: window) else { return true }
            let step = flags.contains(.shift) ? -1 : 1
            tabs[(index + step + tabs.count) % tabs.count].makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }

    // MARK: Menus

    private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func buildMenus() {
        let main = NSMenu()

        let sleepMenu = [0, 1, 5, 10, 30, 60].map { minutes -> NSMenuItem in
            let i = item(minutes == 0 ? "Never" : "\(minutes) min", #selector(setSleepAfter(_:)), target: self)
            i.tag = minutes
            return i
        }
        let engineMenu = SearchEngine.allCases.map { engine -> NSMenuItem in
            let i = item(engine.title, #selector(setSearchEngine(_:)), target: self)
            i.representedObject = engine.rawValue
            return i
        }
        let blockAds = item("Block Ads & Trackers", #selector(toggleBlockAds(_:)), target: self)
        let autoplay = item("Block Autoplay Video", #selector(toggleAutoplay(_:)), target: self)
        let sleepAfter = submenu("Sleep Background Tabs After", sleepMenu)
        let engine = submenu("Search Engine", engineMenu)
        settingsItems = [blockAds, autoplay, sleepAfter, engine]

        main.addItem(submenu("Feather", [
            item("About Feather", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            blockAds, autoplay, sleepAfter, engine,
            .separator(),
            item("Sleep Background Tabs Now", #selector(sleepBackgroundTabs(_:)), "s", [.command, .option], target: self),
            item("Memory Report", #selector(showMemoryReport(_:)), target: self),
            item("Clear Browsing Data…", #selector(clearBrowsingData(_:)), "\u{8}", [.command, .shift], target: self),
            .separator(),
            item("Hide Feather", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Feather", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"),
            item("New Window", #selector(newWindow(_:)), "n", target: self),
            item("New Private Window", #selector(newPrivateWindow(_:)), "n", [.command, .shift], target: self),
            item("Reopen Closed Tab", #selector(reopenClosedTab(_:)), "t", [.command, .shift]),
            item("Open Location", #selector(BrowserWindowController.openLocation(_:)), "l"),
            .separator(),
            item("Close Tab", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(BrowserWindowController.showFindBar(_:)), "f"),
            item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"),
            item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g", [.command, .shift]),
        ]))

        main.addItem(submenu("View", [
            item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"),
            item("Force Reload", #selector(BrowserWindowController.forceReload(_:)), "r", [.command, .shift]),
            .separator(),
            item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        historyMenu.delegate = self
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = historyMenu
        main.addItem(historyItem)

        bookmarksMenu.delegate = self
        let bookmarksItem = NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: "")
        bookmarksItem.submenu = bookmarksMenu
        main.addItem(bookmarksItem)

        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu

        NSApp.mainMenu = main
        refreshSettingsMenu()
    }

    private func refreshSettingsMenu() {
        settingsItems[0].state = Settings.blockAds ? .on : .off
        settingsItems[1].state = Settings.blockAutoplay ? .on : .off
        settingsItems[2].submenu?.items.forEach { $0.state = $0.tag == Settings.sleepAfterMinutes ? .on : .off }
        settingsItems[3].submenu?.items.forEach {
            $0.state = ($0.representedObject as? String) == Settings.searchEngine.rawValue ? .on : .off
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === historyMenu {
            menu.addItem(item("Back", #selector(BrowserWindowController.browserBack(_:)), "["))
            menu.addItem(item("Forward", #selector(BrowserWindowController.browserForward(_:)), "]"))
            menu.addItem(.separator())
            var seen = Set<String>()
            let recent = Store.shared.history.reversed().filter { seen.insert($0.url).inserted }.prefix(25)
            recent.forEach { menu.addItem(pageItem($0)) }
            menu.addItem(.separator())
            menu.addItem(item("Clear History", #selector(clearHistory(_:)), target: self))
        } else if menu === bookmarksMenu {
            menu.addItem(item("Bookmark This Page", #selector(BrowserWindowController.toggleBookmark(_:)), "d"))
            menu.addItem(.separator())
            Store.shared.bookmarks.forEach { menu.addItem(pageItem($0)) }
        }
    }

    private func pageItem(_ entry: PageEntry) -> NSMenuItem {
        let title = entry.title.count > 60 ? String(entry.title.prefix(57)) + "…" : entry.title
        let menuItem = item(title, #selector(openMenuURL(_:)), target: self)
        menuItem.representedObject = URL(string: entry.url)
        menuItem.toolTip = entry.url
        return menuItem
    }
}
