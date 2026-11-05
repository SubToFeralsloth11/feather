import Foundation

struct PageEntry: Codable, Equatable {
    var title: String
    var url: String
    var date: Date?
}

struct SessionTab: Codable {
    var title: String
    var url: String
}

struct SessionWindow: Codable {
    var tabs: [SessionTab]
    var selected: Int
    var frame: String?
}

/// Bookmarks, history and the last session, stored as JSON in Application Support/Feather.
@MainActor
final class Store {
    static let shared = Store()

    private(set) var bookmarks: [PageEntry]
    private(set) var history: [PageEntry]
    private let directory: URL
    private let historyLimit = 1000

    private init() {
        directory = SelfTest.isActive
            ? FileManager.default.temporaryDirectory.appendingPathComponent("feather-selftest-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Feather", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bookmarks = []
        history = []
        bookmarks = load("bookmarks.json") ?? []
        history = load("history.json") ?? []
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Bookmarks

    func isBookmarked(_ url: URL) -> Bool {
        bookmarks.contains { $0.url == url.absoluteString }
    }

    func toggleBookmark(title: String, url: URL) {
        if let index = bookmarks.firstIndex(where: { $0.url == url.absoluteString }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.append(PageEntry(title: title.isEmpty ? url.absoluteString : title, url: url.absoluteString, date: Date()))
        }
        save(bookmarks, "bookmarks.json")
    }

    // MARK: History

    func addHistory(title: String, url: URL) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let entry = PageEntry(title: title.isEmpty ? url.absoluteString : title, url: url.absoluteString, date: Date())
        if let last = history.last, last.url == entry.url {
            history[history.count - 1] = entry
        } else {
            history.append(entry)
        }
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        save(history, "history.json")
    }

    func clearHistory() {
        history.removeAll()
        save(history, "history.json")
    }

    // MARK: Session

    func saveSession(_ windows: [SessionWindow]) {
        save(windows, "session.json")
    }

    func loadSession() -> [SessionWindow] {
        load("session.json") ?? []
    }
}
