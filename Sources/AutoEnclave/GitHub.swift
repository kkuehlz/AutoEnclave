import Foundation
import os

/// Optional GitHub integration. GitHub does not accept user certificates on personal accounts, so instead
/// the throwaway public key itself is registered on mint and removed on revoke, via the `gh` CLI.
/// Needs `gh auth refresh -h github.com -s admin:public_key` once.
enum GitHub {
    static let titlePrefix = "autoenclave:"
    private static let logger = Logger(subsystem: "xyz.category.autoenclave", category: "github")

    static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// e.g. "autoenclave:kevins-macbook-pro": the Mac's name reduced to plain ASCII so it reads cleanly on GitHub.
    static var title: String {
        let name = (Host.current().localizedName ?? "mac").lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return titlePrefix + (name.isEmpty ? "mac" : name)
    }

    /// Registers `publicKeyPath` on the GitHub account after removing any previous AutoEnclave keys. Blocking.
    static func register(publicKeyPath: String) -> Result<Void, AgentError> {
        guard let gh = ghPath else { return .failure(AgentError("gh CLI not found. Install it with: brew install gh")) }
        guard let key = try? String(contentsOfFile: publicKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .failure(AgentError("Could not read \(publicKeyPath)"))
        }
        if case .failure(let e) = unregisterAll() { return .failure(e) }
        let r = Shell.run(gh, ["api", "user/keys", "-f", "title=\(title)", "-f", "key=\(key)"])
        guard r.ok else { return .failure(AgentError(friendly(r.message))) }
        logger.notice("registered ephemeral key on GitHub as \(title, privacy: .public)")
        UserDefaults.standard.set(true, forKey: Prefs.githubEverRegistered)
        return .success(())
    }

    /// Removes every key on the account whose title carries the AutoEnclave prefix. Blocking; returns how many were removed.
    @discardableResult
    static func unregisterAll() -> Result<Int, AgentError> {
        guard let gh = ghPath else { return .failure(AgentError("gh CLI not found. Install it with: brew install gh")) }
        let list = Shell.run(gh, ["api", "user/keys", "--paginate",
                                  "--jq", ".[] | select(.title | startswith(\"\(titlePrefix)\")) | .id"])
        guard list.ok else { return .failure(AgentError(friendly(list.message))) }
        let ids = list.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var removed = 0
        for id in ids {
            let r = Shell.run(gh, ["api", "-X", "DELETE", "user/keys/\(id)"])
            if r.ok { removed += 1 } else { logger.error("failed to delete GitHub key \(id, privacy: .public): \(r.message, privacy: .public)") }
        }
        if removed > 0 { logger.notice("removed \(removed) ephemeral key(s) from GitHub") }
        return .success(removed)
    }

    /// Whether the gh token can manage keys.
    static func hasScope() -> Bool {
        guard let gh = ghPath else { return false }
        return Shell.run(gh, ["api", "user/keys?per_page=1"]).ok
    }

    static var isLoggedIn: Bool {
        guard let gh = ghPath else { return false }
        return Shell.run(gh, ["auth", "status", "-h", "github.com"]).ok
    }

    static let deviceURL = URL(string: "https://github.com/login/device")!

    /// Runs `gh auth refresh` to add the key-management scope. Without a terminal, gh prints a one-time code
    /// and the device URL but does not open a browser, so `onCode` fires as soon as the code appears and the
    /// caller opens the page. Blocks until gh exits, i.e. until the user approves in the browser.
    static func grantScope(onCode: @escaping (String) -> Void) -> Result<Void, AgentError> {
        guard let gh = ghPath else { return .failure(AgentError("gh CLI not found. Install it with: brew install gh")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["auth", "refresh", "-h", "github.com", "-s", "admin:public_key"]
        var env = ProcessInfo.processInfo.environment
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_PROMPT_DISABLED"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        var collected = ""
        var codeSeen = false
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            lock.lock(); collected += chunk; let all = collected; lock.unlock()
            if !codeSeen, let r = all.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4}"#, options: .regularExpression) {
                codeSeen = true
                onCode(String(all[r]))
            }
        }
        do { try p.run() } catch { return .failure(AgentError("Could not run gh: \(error.localizedDescription)")) }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lock.lock(); collected += rest; let output = collected; lock.unlock()
        if p.terminationStatus == 0 { return .success(()) }
        return .failure(AgentError("gh auth refresh failed: " + output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private static func friendly(_ message: String) -> String {
        if message.contains("admin:public_key") || message.contains("404") {
            return "GitHub: the gh token lacks the admin:public_key scope. Grant it in the GitHub tab."
        }
        if message.contains("not logged") || message.contains("auth login") {
            return "GitHub: gh is not logged in. Run: gh auth login"
        }
        return "GitHub: " + message
    }
}
