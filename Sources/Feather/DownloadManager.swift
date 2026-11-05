import AppKit
import WebKit

/// Saves downloads to ~/Downloads and bounces the Downloads stack in the Dock when one finishes.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void)
    {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let numbered = "\(base) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
            url = folder.appendingPathComponent(numbered)
            counter += 1
        }
        destinations[ObjectIdentifier(download)] = url
        NSApp.dockTile.badgeLabel = "↓"
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        if destinations.isEmpty { NSApp.dockTile.badgeLabel = nil }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let url = destinations.removeValue(forKey: ObjectIdentifier(download))
        if destinations.isEmpty { NSApp.dockTile.badgeLabel = nil }
        let alert = NSAlert()
        alert.messageText = "Download failed"
        alert.informativeText = "\(url?.lastPathComponent ?? "File"): \(error.localizedDescription)"
        alert.runModal()
    }
}
