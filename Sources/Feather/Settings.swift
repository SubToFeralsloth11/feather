import Foundation

enum SearchEngine: String, CaseIterable {
    case google, duckduckgo, bing

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func url(for query: String) -> URL? {
        let base: String
        switch self {
        case .google: base = "https://www.google.com/search"
        case .duckduckgo: base = "https://duckduckgo.com/"
        case .bing: base = "https://www.bing.com/search"
        }
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}

/// User preferences, persisted in UserDefaults.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var blockAds: Bool {
        get { defaults.object(forKey: "blockAds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "blockAds") }
    }

    static var blockAutoplay: Bool {
        get { defaults.object(forKey: "blockAutoplay") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "blockAutoplay") }
    }

    /// Minutes a tab may stay in the background before it is put to sleep. 0 = never.
    static var sleepAfterMinutes: Int {
        get { defaults.object(forKey: "sleepAfterMinutes") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "sleepAfterMinutes") }
    }

    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: defaults.string(forKey: "searchEngine") ?? "") ?? .google }
        set { defaults.set(newValue.rawValue, forKey: "searchEngine") }
    }

    /// Turns address-bar input into a URL: a real address when it looks like one, otherwise a search.
    static func url(fromInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about", "data"].contains(scheme) {
            return url
        }
        if !text.contains(" ") {
            if text.hasPrefix("localhost")
                || text.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
                return URL(string: "http://" + text)
            }
            if text.contains("."), !text.hasSuffix("."),
               let url = URL(string: "https://" + text), let host = url.host, host.contains(".") {
                return url
            }
        }
        return searchEngine.url(for: text)
    }
}
