import Foundation

/// Reads Google Chrome's bookmarks (every profile, local and account-stored) from its JSON files.
enum ChromeImport {
    static let chromeDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)

    /// Chrome keeps device bookmarks in `Bookmarks` and account-stored ones in `AccountBookmarks`.
    private static let files = ["Bookmarks", "AccountBookmarks"]
    private static let roots = ["bookmark_bar", "other", "synced"]

    static var isAvailable: Bool { !profiles().isEmpty }

    /// Profile folders that contain bookmarks, with their display names from Chrome's Local State.
    static func profiles() -> [(directory: URL, name: String)] {
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: chromeDirectory.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        {
            for (folder, info) in cache {
                if let name = (info as? [String: Any])?["name"] as? String { names[folder] = name }
            }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: chromeDirectory.path)) ?? []
        return folders.sorted().compactMap { folder in
            let directory = chromeDirectory.appendingPathComponent(folder, isDirectory: true)
            let hasBookmarks = files.contains {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
            return hasBookmarks ? (directory, names[folder] ?? folder) : nil
        }
    }

    /// All bookmarks, with Chrome's folder structure. Duplicate URLs are kept once.
    static func bookmarks() -> [PageEntry] {
        let profiles = profiles()
        var seen = Set<String>()
        var result: [PageEntry] = []
        for profile in profiles {
            let prefix = profiles.count > 1 ? [profile.name] : []
            for file in files {
                guard let data = try? Data(contentsOf: profile.directory.appendingPathComponent(file)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rootNodes = json["roots"] as? [String: Any]
                else { continue }
                for key in roots {
                    guard let root = rootNodes[key] as? [String: Any] else { continue }
                    let name = root["name"] as? String ?? key
                    walk(root, path: prefix + [name], into: &result, seen: &seen)
                }
            }
        }
        return result
    }

    private static func walk(_ node: [String: Any], path: [String], into result: inout [PageEntry], seen: inout Set<String>) {
        for child in node["children"] as? [[String: Any]] ?? [] {
            let name = child["name"] as? String ?? ""
            switch child["type"] as? String {
            case "url":
                guard let url = child["url"] as? String, seen.insert(url).inserted else { continue }
                result.append(PageEntry(title: name.isEmpty ? url : name, url: url,
                                        date: chromeDate(child["date_added"]), folder: path))
            case "folder":
                walk(child, path: path + [name], into: &result, seen: &seen)
            default:
                continue
            }
        }
    }

    /// Chrome stores times as microseconds since 1601-01-01.
    private static func chromeDate(_ value: Any?) -> Date? {
        guard let text = value as? String, let micro = Double(text), micro > 0 else { return nil }
        return Date(timeIntervalSince1970: micro / 1_000_000 - 11_644_473_600)
    }
}
