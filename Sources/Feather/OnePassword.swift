import AppKit
import WebKit

/// 1Password integration through the 1Password CLI (`op`), which the 1Password app unlocks
/// (Touch ID / password prompt) when Settings ▸ Developer ▸ "Integrate with 1Password CLI" is on.
@MainActor
enum OnePassword {
    struct Login {
        let id: String
        let title: String
        let username: String
        let hosts: [String]
    }

    struct Credentials {
        var username: String?
        var password: String?
        var oneTimeCode: String?
    }

    enum Failure: LocalizedError {
        case notInstalled
        case notConnected(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "The 1Password command-line tool isn't installed. Install it with: brew install --cask 1password-cli"
            case .notConnected:
                return "Feather can't reach 1Password yet. Open 1Password ▸ Settings ▸ Developer and turn on "
                    + "\"Integrate with 1Password CLI\", then try again."
            case .failed(let message):
                return message
            }
        }
    }

    static var cliPath: String? {
        ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Matching

    /// The part of a host a site's logins are shared across: "accounts.google.com" → "google.com",
    /// "www.bbc.co.uk" → "bbc.co.uk".
    nonisolated static func siteDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel = ["co", "com", "org", "net", "gov", "ac", "edu", "ne", "or"]
        let keep = labels.last!.count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Logins saved for the page's site, exact-host matches first.
    nonisolated static func matching(_ logins: [Login], host: String) -> [Login] {
        let host = host.lowercased()
        let site = siteDomain(host)
        func exact(_ login: Login) -> Bool { login.hosts.contains { $0 == host || "www." + $0 == host || $0 == "www." + host } }
        return logins
            .filter { $0.hosts.contains { siteDomain($0) == site } }
            .sorted { exact($0) && !exact($1) }
    }

    // MARK: CLI

    private static func run(_ arguments: [String]) async throws -> Data {
        guard let path = cliPath else { throw Failure.notInstalled }
        let (status, data, message) = try await Task.detached { () throws -> (Int32, Data, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do { try process.run() } catch { throw Failure.failed(error.localizedDescription) }
            // Drain stdout before waiting: a full pipe would otherwise block `op` forever.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, data, message.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
        if status == 0 { return data }
        let lower = message.lowercased()
        if ["sign in", "signed in", "no account", "desktop app", "authoriz", "not currently"].contains(where: lower.contains) {
            throw Failure.notConnected(message)
        }
        throw Failure.failed(message.isEmpty ? "1Password returned an error." : message)
    }

    static func logins() async throws -> [Login] {
        let data = try await run(["item", "list", "--categories", "Login", "--format", "json"])
        let items = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let hosts = (item["urls"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
                guard let href = entry["href"] as? String else { return nil }
                return (URL(string: href)?.host ?? URL(string: "https://" + href)?.host)?.lowercased()
            }
            return Login(id: id, title: item["title"] as? String ?? "Login",
                         username: item["additional_information"] as? String ?? "", hosts: hosts)
        }
    }

    static func credentials(for login: Login) async throws -> Credentials {
        let data = try await run(["item", "get", login.id, "--format", "json", "--reveal"])
        let item = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        var result = Credentials()
        for field in item["fields"] as? [[String: Any]] ?? [] {
            let value = field["value"] as? String
            switch (field["purpose"] as? String, field["type"] as? String) {
            case ("USERNAME", _): result.username = value
            case ("PASSWORD", _): result.password = value
            case (_, "OTP"): result.oneTimeCode = field["totp"] as? String
            default: break
            }
        }
        return result
    }

    // MARK: Filling

    /// Fills the page's visible login form. Runs in an isolated script world so the page can't intercept it.
    /// Returns what was filled, e.g. ["username", "password"].
    static func fill(_ credentials: Credentials, into webView: WKWebView) async throws -> [String] {
        let result = try await webView.callAsyncJavaScript(
            fillScript,
            arguments: [
                "username": credentials.username ?? "",
                "password": credentials.password ?? "",
                "code": credentials.oneTimeCode ?? "",
            ],
            contentWorld: .defaultClient)
        return (result as? String)?.split(separator: ",").map(String.init) ?? []
    }

    static let fillScript = """
    const visible = (el) => {
      const r = el.getBoundingClientRect(), s = getComputedStyle(el);
      return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && !el.disabled && !el.readOnly;
    };
    const inputs = [...document.querySelectorAll('input')].filter(visible);
    const describe = (el) => [el.name, el.id, el.placeholder, el.getAttribute('aria-label'), el.autocomplete].join(' ');
    const isCode = (el) => el.autocomplete === 'one-time-code'
      || /otp|totp|2fa|mfa|one.?time|verification|security.?code|auth.?code/i.test(describe(el));
    const isText = (el) => ['text', 'email', 'tel', ''].includes(el.type) && !isCode(el);
    const set = (el, value) => {
      el.focus();
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const filled = [];
    const passwordField = inputs.find((el) => el.type === 'password');
    let userField = inputs.find((el) => isText(el) && /username|email/.test(el.autocomplete));
    if (!userField && passwordField) {
      userField = inputs.slice(0, inputs.indexOf(passwordField)).reverse().find(isText);
    }
    if (!userField && !passwordField) {
      userField = inputs.find((el) => isText(el) && (el.type === 'email' || /user|email|login|account/i.test(describe(el))));
    }
    if (userField && username) { set(userField, username); filled.push('username'); }
    if (passwordField && password) { set(passwordField, password); filled.push('password'); }
    if (!userField && !passwordField && code) {
      const codeField = inputs.find(isCode);
      if (codeField) { set(codeField, code); filled.push('code'); }
    }
    return filled.join(',');
    """
}
