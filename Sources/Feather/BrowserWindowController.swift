import AppKit
import WebKit

/// One browser tab. Tabs are native macOS window tabs, so each tab owns a window.
///
/// Memory model: the WKWebView (and with it the page's web process) only exists while it is needed.
/// New tabs and restored tabs have none until they are shown, and background tabs are put to sleep
/// after `Settings.sleepAfterMinutes` (or right away under memory pressure); waking restores
/// history and scroll position from `interactionState`.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    NSToolbarDelegate, NSTextFieldDelegate, NSMenuItemValidation
{
    static private(set) var all: [BrowserWindowController] = []
    private static var closedTabs: [URL] = []

    let isPrivate: Bool
    private(set) var webView: WKWebView?
    private var pendingURL: URL?
    private var savedState: Any?
    private var pageTitle = "New Tab"
    private(set) var lastActive = Date()
    private var observations: [NSKeyValueObservation] = []
    /// Frames currently playing sound, keyed by an id each frame picks (see `Engine.audioScript`).
    private var audibleFrames = Set<String>()

    var isPlayingSound: Bool { !audibleFrames.isEmpty }

    func setFrame(_ id: String, audible: Bool) {
        if audible { audibleFrames.insert(id) } else { audibleFrames.remove(id) }
    }

    private let container = NSView()
    private let placeholder = PlaceholderView()
    private let progressBar = ProgressBar()
    private let findBar = FindBar()
    private let addressField = NSTextField()
    private var backItem: NSToolbarItem?
    private var forwardItem: NSToolbarItem?
    private var reloadItem: NSToolbarItem?
    private var bookmarkItem: NSToolbarItem?

    var isAsleep: Bool { webView == nil && (pendingURL != nil || savedState != nil) }

    var currentURL: URL? { webView?.url ?? pendingURL }
    var currentTitle: String { pageTitle }

    /// True when this tab is the one showing in its window.
    var isShowing: Bool {
        guard let window, !window.isMiniaturized else { return false }
        return (window.tabGroup?.selectedWindow ?? window) === window && window.isVisible
    }

    // MARK: Creation

    private init(isPrivate: Bool) {
        self.isPrivate = isPrivate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = isPrivate ? "Feather.private" : "Feather"
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        if isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        super.init(window: window)
        window.delegate = self
        buildContent()
        buildToolbar()
        showPlaceholder()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Opens a tab. `host` is a window to join as a new tab; nil opens a new window.
    /// `lazy` tabs don't load until shown. `configuration` is WebKit's, for pages opened by script.
    @discardableResult
    static func open(url: URL?, title: String? = nil, in host: NSWindow?, isPrivate: Bool,
                     select: Bool = true, lazy: Bool = false,
                     configuration: WKWebViewConfiguration? = nil) -> BrowserWindowController
    {
        let controller = BrowserWindowController(isPrivate: isPrivate)
        all.append(controller)
        let window = controller.window!
        if SelfTest.isActive { SelfTest.hide(window) }
        controller.pageTitle = title ?? (url == nil ? "New Tab" : url!.host ?? url!.absoluteString)
        window.title = controller.pageTitle
        if let url {
            controller.pendingURL = url
            controller.addressField.stringValue = url.absoluteString
        }
        if let host {
            window.setFrame(host.frame, display: false)
            host.addTabbedWindow(window, ordered: .above)
            if select { window.makeKeyAndOrderFront(nil) } else { host.makeKeyAndOrderFront(nil) }
        } else {
            if let key = NSApp.keyWindow {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
            } else {
                window.center()
            }
            if select || NSApp.keyWindow == nil { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        }
        if configuration != nil {
            controller.ensureWebView(configuration: configuration)
        } else if url != nil && !lazy && select {
            controller.ensureWebView()
        } else if url != nil {
            controller.markAsleep(true)
        }
        controller.showPlaceholder()
        if url == nil && configuration == nil { controller.focusAddressBar() }
        return controller
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        container.autoresizesSubviews = true
        placeholder.frame = container.bounds
        placeholder.autoresizingMask = [.width, .height]
        findBar.isHidden = true
        findBar.onFind = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }

        let stack = NSStackView(views: [findBar, container])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(progressBar)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            progressBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: container.topAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        container.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    // MARK: Toolbar

    private static let backID = NSToolbarItem.Identifier("back")
    private static let forwardID = NSToolbarItem.Identifier("forward")
    private static let reloadID = NSToolbarItem.Identifier("reload")
    private static let addressID = NSToolbarItem.Identifier("address")
    private static let bookmarkID = NSToolbarItem.Identifier("bookmark")

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "Feather.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.backID, Self.forwardID, Self.reloadID, Self.addressID, Self.bookmarkID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
    {
        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.target = self
            item.action = action
            item.isBordered = true
            item.autovalidates = false
            return item
        }
        switch id {
        case Self.backID:
            backItem = button("chevron.left", "Back", #selector(browserBack(_:)))
            backItem?.isEnabled = false
            return backItem
        case Self.forwardID:
            forwardItem = button("chevron.right", "Forward", #selector(browserForward(_:)))
            forwardItem?.isEnabled = false
            return forwardItem
        case Self.reloadID:
            reloadItem = button("arrow.clockwise", "Reload", #selector(reloadOrStop(_:)))
            return reloadItem
        case Self.bookmarkID:
            bookmarkItem = button("star", "Bookmark", #selector(toggleBookmark(_:)))
            return bookmarkItem
        case Self.addressID:
            let item = NSToolbarItem(itemIdentifier: id)
            addressField.placeholderString = "Search \(Settings.searchEngine.title) or enter address"
            addressField.bezelStyle = .roundedBezel
            addressField.font = .systemFont(ofSize: 13)
            addressField.lineBreakMode = .byTruncatingTail
            addressField.cell?.isScrollable = true
            addressField.cell?.wraps = false
            addressField.delegate = self
            addressField.translatesAutoresizingMaskIntoConstraints = false
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
            let preferred = addressField.widthAnchor.constraint(equalToConstant: 4000)
            preferred.priority = .defaultLow
            preferred.isActive = true
            item.view = addressField
            item.visibilityPriority = .high
            item.label = "Address"
            return item
        default:
            return nil
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === addressField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if let url = Settings.url(fromInput: addressField.stringValue) {
                load(url)
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            addressField.stringValue = currentURL?.absoluteString ?? ""
            if let webView { window?.makeFirstResponder(webView) }
            return true
        }
        return false
    }

    // MARK: Web view lifecycle

    @discardableResult
    func ensureWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let webView { return webView }
        let config = configuration ?? Engine.makeConfiguration(isPrivate: isPrivate)
        let webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        placeholder.removeFromSuperview()
        container.addSubview(webView)
        self.webView = webView
        observe(webView)
        markAsleep(false)

        if let state = savedState {
            savedState = nil
            webView.interactionState = state
            if webView.url == nil, let url = pendingURL { webView.load(URLRequest(url: url)) }
        } else if let url = pendingURL {
            webView.load(URLRequest(url: url))
        }
        pendingURL = nil
        if window?.firstResponder === window || window?.firstResponder == nil {
            window?.makeFirstResponder(webView)
        }
        return webView
    }

    /// Frees this tab's web view and web process. The page comes back when the tab is shown again.
    func sleep() {
        guard let webView else { return }
        savedState = webView.interactionState
        pendingURL = webView.url
        tearDown(webView)
        progressBar.progress = 0
        showPlaceholder()
        markAsleep(pendingURL != nil)
    }

    /// Sleeps the tab unless it is showing, playing sound or using the camera/microphone.
    func sleepIfIdle() {
        guard let webView, !isShowing, !isPlayingSound else { return }
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return }
        sleep()
    }

    private func tearDown(_ webView: WKWebView) {
        observations.removeAll()
        audibleFrames.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
    }

    private func showPlaceholder() {
        guard webView == nil else { return }
        if isAsleep {
            placeholder.show(title: pageTitle, detail: "This tab was asleep to save memory. Loading…")
        } else {
            placeholder.show(title: isPrivate ? "Private Tab" : "Feather",
                             detail: isPrivate
                                 ? "Nothing from this window is saved: no history, no cookies."
                                 : "Search or type an address above.")
        }
        if placeholder.superview == nil {
            placeholder.frame = container.bounds
            container.addSubview(placeholder)
        }
    }

    private func markAsleep(_ asleep: Bool) {
        guard let tab = window?.tab else { return }
        if asleep {
            let image = NSImageView(image: NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Asleep")!)
            image.contentTintColor = .secondaryLabelColor
            tab.accessoryView = image
        } else {
            tab.accessoryView = nil
        }
    }

    private func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.title) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let title = webView.title, !title.isEmpty else { return }
                    self.pageTitle = title
                    self.window?.title = title
                }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.updateAddress() }
            },
            webView.observe(\.estimatedProgress) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.updateProgress() }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateProgress() }
            },
            webView.observe(\.canGoBack) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.backItem?.isEnabled = webView.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.forwardItem?.isEnabled = webView.canGoForward }
            },
        ]
    }

    private func updateAddress() {
        let url = currentURL
        if addressField.currentEditor() == nil {
            addressField.stringValue = url?.absoluteString ?? ""
        }
        let marked = url.map { Store.shared.isBookmarked($0) } ?? false
        bookmarkItem?.image = NSImage(systemSymbolName: marked ? "star.fill" : "star", accessibilityDescription: "Bookmark")
    }

    private func updateProgress() {
        guard let webView else { return }
        progressBar.progress = webView.isLoading ? max(0.08, webView.estimatedProgress) : 0
        reloadItem?.image = NSImage(systemSymbolName: webView.isLoading ? "xmark" : "arrow.clockwise",
                                    accessibilityDescription: webView.isLoading ? "Stop" : "Reload")
    }

    // MARK: Actions

    func load(_ url: URL) {
        let webView = ensureWebView()
        webView.load(URLRequest(url: url))
        window?.makeFirstResponder(webView)
    }

    func focusAddressBar() {
        window?.makeFirstResponder(addressField)
        addressField.selectText(nil)
    }

    @objc func browserBack(_ sender: Any?) { webView?.goBack() }
    @objc func browserForward(_ sender: Any?) { webView?.goForward() }

    @objc func reloadOrStop(_ sender: Any?) {
        guard let webView else { if isAsleep { ensureWebView() }; return }
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    @objc func reloadPage(_ sender: Any?) {
        if let webView { webView.reload() } else if isAsleep { ensureWebView() }
    }

    @objc func forceReload(_ sender: Any?) { webView?.reloadFromOrigin() }
    @objc func openLocation(_ sender: Any?) { focusAddressBar() }

    @objc func zoomIn(_ sender: Any?) { webView?.pageZoom = min(5, (webView?.pageZoom ?? 1) + 0.1) }
    @objc func zoomOut(_ sender: Any?) { webView?.pageZoom = max(0.3, (webView?.pageZoom ?? 1) - 0.1) }
    @objc func actualSize(_ sender: Any?) { webView?.pageZoom = 1 }

    @objc func toggleBookmark(_ sender: Any?) {
        guard let url = currentURL else { return }
        Store.shared.toggleBookmark(title: pageTitle, url: url)
        updateAddress()
    }

    override func newWindowForTab(_ sender: Any?) {
        BrowserWindowController.open(url: nil, in: window, isPrivate: isPrivate)
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        BrowserWindowController.reopenClosedTab(in: window)
    }

    static func reopenClosedTab(in host: NSWindow?) {
        guard let url = closedTabs.popLast() else { NSSound.beep(); return }
        open(url: url, in: host, isPrivate: false)
    }

    @objc func showFindBar(_ sender: Any?) {
        findBar.isHidden = false
        window?.makeFirstResponder(findBar.field)
        findBar.field.selectText(nil)
    }

    @objc func findNext(_ sender: Any?) { find(findBar.field.stringValue, backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(findBar.field.stringValue, backwards: true) }

    private func hideFindBar() {
        findBar.isHidden = true
        if let webView { window?.makeFirstResponder(webView) }
    }

    private func find(_ text: String, backwards: Bool) {
        guard let webView, !text.isEmpty else { findBar.setFound(true); return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            self?.findBar.setFound(result.matchFound)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(browserBack(_:)): return webView?.canGoBack ?? false
        case #selector(browserForward(_:)): return webView?.canGoForward ?? false
        case #selector(toggleBookmark(_:)):
            let marked = currentURL.map { Store.shared.isBookmarked($0) } ?? false
            item.title = marked ? "Remove Bookmark" : "Bookmark This Page"
            return currentURL != nil
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)),
             #selector(forceReload(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)),
             #selector(showFindBar(_:)):
            return webView != nil
        default: return true
        }
    }

    // MARK: Window delegate

    func windowDidBecomeKey(_ notification: Notification) {
        lastActive = Date()
        if webView == nil && isAsleep { ensureWebView() }
    }

    func windowDidResignKey(_ notification: Notification) {
        lastActive = Date()
    }

    func windowWillClose(_ notification: Notification) {
        if !isPrivate, let url = currentURL { Self.closedTabs.append(url) }
        if Self.closedTabs.count > 25 { Self.closedTabs.removeFirst() }
        if let webView { tearDown(webView) }
        Self.all.removeAll { $0 === self }
        if isPrivate && !Self.all.contains(where: { $0.isPrivate }) { Engine.discardPrivateStore() }
    }

    // MARK: Navigation delegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void)
    {
        if action.shouldPerformDownload { decisionHandler(.download, preferences); return }
        guard let url = action.request.url else { decisionHandler(.allow, preferences); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "file", "data", "blob", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel, preferences)
            return
        }
        // ⌘-click or middle-click: open in a background tab.
        if action.navigationType == .linkActivated,
           action.modifierFlags.contains(.command) || action.buttonNumber == 2
        {
            let select = action.modifierFlags.contains(.shift)
            BrowserWindowController.open(url: url, in: window, isPrivate: isPrivate, select: select)
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void)
    {
        let disposition = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !response.canShowMIMEType || (response.isForMainFrame && disposition.hasPrefix("attachment")) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateAddress()
        if !isPrivate, let url = webView.url {
            Store.shared.addHistory(title: webView.title ?? "", url: url)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let error = error as NSError
        // Cancelled loads and loads that turned into downloads are not errors.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204) { return }
        let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <html><head><meta name="color-scheme" content="light dark"><title>Can't open page</title>
        <style>body{font:15px -apple-system;max-width:520px;margin:18vh auto;padding:0 24px;color:#666}
        h1{font-size:24px;color:CanvasText}button{font:inherit;padding:6px 16px}</style></head>
        <body><h1>This page can't be opened</h1><p>\(message)</p>
        <button onclick="location.reload()">Try again</button></body></html>
        """
        webView.loadHTMLString(html, baseURL: failing)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: UI delegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView?
    {
        let tab = BrowserWindowController.open(url: nil, in: window, isPrivate: isPrivate, configuration: configuration)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        window?.close()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void)
    {
        let alert = makeAlert(message, frame)
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void)
    {
        let alert = makeAlert(message, frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void)
    {
        let alert = makeAlert(prompt, frame)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    private func makeAlert(_ message: String, _ frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        return alert
    }

    private func present(_ alert: NSAlert, _ handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void)
    {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void)
    {
        decisionHandler(.prompt)
    }
}
