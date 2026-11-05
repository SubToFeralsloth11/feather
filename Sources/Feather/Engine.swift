import AppKit
import WebKit

/// Shared WebKit setup: one content controller (ad blocking) and the data stores for normal and private tabs.
@MainActor
enum Engine {
    static let contentController = WKUserContentController()
    private static var blockList: WKContentRuleList?
    private static var privateStore: WKWebsiteDataStore?

    /// Ad, tracker and popunder hosts. Requests to them from other sites are blocked.
    private static let blockedHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagservices.com", "googletagmanager.com", "adservice.google.com", "2mdn.net",
        "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "advertising.com", "taboola.com",
        "outbrain.com", "criteo.com", "criteo.net", "rubiconproject.com", "pubmatic.com", "openx.net",
        "casalemedia.com", "scorecardresearch.com", "quantserve.com", "quantcount.com", "moatads.com",
        "adform.net", "smartadserver.com", "yieldmo.com", "33across.com", "sharethrough.com",
        "indexww.com", "bidswitch.net", "media.net", "zedo.com", "revcontent.com", "mgid.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "crazyegg.com", "chartbeat.com",
        "connect.facebook.net", "analytics.twitter.com", "ads-twitter.com", "bat.bing.com",
        "ads.linkedin.com", "teads.tv", "adsafeprotected.com", "doubleverify.com", "serving-sys.com",
        "trafficjunky.net", "exoclick.com", "popads.net", "propellerads.com", "adsterra.com",
        "onclickads.net", "popcash.net", "adcolony.com", "applovin.com", "inmobi.com", "contextweb.com",
        "lijit.com", "sovrn.com", "gumgum.com", "triplelift.com", "3lift.com", "spotxchange.com",
        "springserve.com", "adroll.com", "demdex.net", "everesttech.net", "krxd.net", "bluekai.com",
        "exelator.com", "agkn.com", "mathtag.com", "rlcdn.com", "tapad.com", "zemanta.com",
        "yieldlove.com", "adition.com", "imrworldwide.com", "branch.io", "clarity.ms",
    ]

    private static let hiddenElements = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^='google_ads_iframe']", "[id^='div-gpt-ad']",
        "iframe[src*='doubleclick.net']", "iframe[src*='googlesyndication.com']",
        ".trc_rbox_container", ".OUTBRAIN", "[data-google-query-id]",
    ]

    private static var rulesJSON: String {
        var rules: [[String: Any]] = blockedHosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?\(escaped)[:/]", "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": hiddenElements.joined(separator: ", ")],
        ])
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }

    /// Bump when the rule list changes so the compiled copy is rebuilt.
    private static let ruleListID = "feather-blocklist-v1"

    static func prepare(_ completion: @escaping () -> Void) {
        let store = WKContentRuleListStore.default()!
        store.lookUpContentRuleList(forIdentifier: ruleListID) { list, _ in
            if let list {
                blockList = list
                applyBlocking()
                completion()
                return
            }
            store.compileContentRuleList(forIdentifier: ruleListID, encodedContentRuleList: rulesJSON) { list, error in
                if let error { NSLog("Feather: blocklist failed to compile: \(error)") }
                blockList = list
                applyBlocking()
                completion()
            }
        }
    }

    static func applyBlocking() {
        guard let blockList else { return }
        contentController.remove(blockList)
        if Settings.blockAds { contentController.add(blockList) }
    }

    static func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        if isPrivate {
            if privateStore == nil { privateStore = .nonPersistent() }
            config.websiteDataStore = privateStore!
        } else {
            config.websiteDataStore = .default()
        }
        config.userContentController = contentController
        // Identify as Safari so sites serve their full desktop pages.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.mediaTypesRequiringUserActionForPlayback = Settings.blockAutoplay ? .all : []
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        return config
    }

    /// Called when the last private tab closes, so the next private window starts with no cookies.
    static func discardPrivateStore() {
        privateStore = nil
    }
}
