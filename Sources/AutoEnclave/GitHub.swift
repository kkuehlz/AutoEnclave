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

    static var title: String { titlePrefix + Host.current().localizedName.map { $0.replacingOccurrences(of: " ", with: "-") }!.lowercased() }

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

    /// Runs `gh auth refresh` to add the key-management scope. gh prints a one-time code and opens the browser;
    /// `onCode` receives the code as soon as it appears so the UI can show it. Blocks until gh exits.
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
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            lock.lock(); collected += chunk; let all = collected; lock.unlock()
            if let r = all.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4}"#, options: .regularExpression) {
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

    /// Fallback: run the grant in Terminal.app where gh can prompt normally.
    static func grantScopeInTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "gh auth refresh -h github.com -s admin:public_key"
        end tell
        """
        _ = Shell.run("/usr/bin/osascript", ["-e", script])
    }

    private static func friendly(_ message: String) -> String {
        if message.contains("admin:public_key") || message.contains("404") {
            return "GitHub: the gh token lacks the admin:public_key scope. Run once in a terminal:\n  gh auth refresh -h github.com -s admin:public_key"
        }
        if message.contains("not logged") || message.contains("auth login") {
            return "GitHub: gh is not logged in. Run: gh auth login"
        }
        return "GitHub: " + message
    }
}
