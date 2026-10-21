import AppKit
import Foundation
import os

enum KeyState: Equatable {
    case absent
    case keyOnly                 // private key exists but no certificate next to it
    case valid(until: Date)
    case expired(at: Date)

    var isPresent: Bool { self != .absent }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
}

/// Owns the throwaway key on disk: minting, inspection and deletion.
@MainActor
final class KeyManager: ObservableObject {
    static let shared = KeyManager()

    @Published private(set) var state: KeyState = .absent
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?
    @Published private(set) var log: [LogEntry] = []

    private let logger = Logger(subsystem: "xyz.category.autoenclave", category: "keys")
    private var expiryTimer: Timer?

    private init() {
        // SwiftUI creates this before the app delegate runs, so defaults must be in place here or the
        // key path reads as empty and the state looks like "no key".
        Prefs.registerDefaults()
        Prefs.migrate()
        refresh()
    }

    // MARK: Paths

    var privateKeyPath: String { Prefs.expandedKeyPath }
    var publicKeyPath: String { privateKeyPath + ".pub" }
    var certPath: String { privateKeyPath + "-cert.pub" }

    private var allPaths: [String] { [privateKeyPath, publicKeyPath, certPath] }

    // MARK: Inspection

    func refresh() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: privateKeyPath) else {
            setState(.absent)
            return
        }
        guard fm.fileExists(atPath: certPath) else {
            setState(.keyOnly)
            return
        }
        let result = Shell.run("/usr/bin/ssh-keygen", ["-L", "-f", certPath])
        guard result.ok, let until = Self.parseValidUntil(result.stdout) else {
            // Certificate unreadable; treat as plain key.
            setState(.keyOnly)
            return
        }
        setState(until > Date() ? .valid(until: until) : .expired(at: until))
    }

    private func setState(_ new: KeyState) {
        state = new
        scheduleExpiryTimer()
    }

    /// Parses the "Valid: from X to Y" line of `ssh-keygen -L`. Returns nil for "forever" or unparseable.
    nonisolated static func parseValidUntil(_ output: String) -> Date? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Valid:") else { continue }
            guard let range = trimmed.range(of: " to ") else { return nil }
            let stamp = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f.date(from: stamp)
        }
        return nil
    }

    private func scheduleExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard case .valid(let until) = state else { return }
        // Fire a second after expiry so the parsed state flips to .expired.
        let t = Timer(fire: until.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                if Prefs.bool(Prefs.deleteOnExpiry) {
                    self.deleteKey(reason: "certificate expired")
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        expiryTimer = t
    }

    // MARK: Minting

    /// Generates a fresh ed25519 key and signs it through the agent. Secretive prompts once for the CA signature.
    func mint() async {
        guard !busy else { return }
        busy = true
        lastError = nil
        defer { busy = false }

        let keyPath = privateKeyPath
        let caPath = Prefs.expandedCAPath
        let identity = Prefs.string(Prefs.certIdentity)
        let principals = Prefs.string(Prefs.principals)
        let hours = max(1, Prefs.int(Prefs.validityHours))
        let socket = Prefs.expandedAgentSocket
        let paths = allPaths
        let github = Prefs.bool(Prefs.githubRegister)
        let cleanupGitHub = githubInvolved && GitHub.ghPath != nil

        guard FileManager.default.fileExists(atPath: socket) else {
            fail("Agent socket not found at \(socket). Is Secretive running?")
            return
        }
        // Make sure the CA public key file holds the key chosen in Settings.
        var caLine = Prefs.string(Prefs.caKeyLine)
        if caLine.isEmpty {
            // Nothing chosen yet: if Secretive holds exactly one key, that's the CA. Otherwise the user must pick.
            switch AgentKeys.list(socket: socket) {
            case .failure(let err):
                fail(err.description); return
            case .success(let keys) where keys.count == 1:
                caLine = keys[0].line
                UserDefaults.standard.set(caLine, forKey: Prefs.caKeyLine)
                note("Using Secretive's only key (\(keys[0].fingerprint)) as the CA")
            case .success(let keys) where keys.isEmpty:
                fail("No key in Secretive. Is Secretive running with a key?"); return
            case .success:
                fail("Secretive has several keys. Open Settings → General and choose which one is the CA."); return
            }
        }
        do {
            try FileManager.default.createDirectory(atPath: (caPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let existing = try? String(contentsOfFile: caPath, encoding: .utf8)
            if existing?.trimmingCharacters(in: .whitespacesAndNewlines) != caLine {
                try (caLine + "\n").write(toFile: caPath, atomically: true, encoding: .utf8)
                note("Wrote CA public key to \(caPath)")
            }
        } catch {
            fail("Could not write CA public key to \(caPath): \(error.localizedDescription)"); return
        }

        let error: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            let fm = FileManager.default
            let dir = (keyPath as NSString).deletingLastPathComponent
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                return "Could not create \(dir): \(error.localizedDescription)"
            }
            for p in paths where fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
            if cleanupGitHub, !github {
                // Feature is off now but a key may still be up there from before: take it down and leave it down.
                _ = GitHub.unregisterAll()
            }
            // (When GitHub is on, register() below removes old keys itself before adding the new one.)

            let comment = "autoenclave \(identity) \(ISO8601DateFormatter().string(from: Date()))"
            let gen = Shell.run("/usr/bin/ssh-keygen",
                                ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", keyPath])
            guard gen.ok else { return "Key generation failed: \(gen.message)" }

            let sign = Shell.run("/usr/bin/ssh-keygen",
                                 ["-Us", caPath, "-I", identity, "-n", principals, "-V", "+\(hours)h", keyPath + ".pub"],
                                 env: ["SSH_AUTH_SOCK": socket])
            guard sign.ok else {
                for p in paths where fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
                return "Signing failed: \(sign.message)"
            }
            if github, case .failure(let e) = GitHub.register(publicKeyPath: keyPath + ".pub") {
                // Local mint still succeeded; GitHub is best effort and reported separately.
                return "github:" + e.description
            }
            return nil
        }.value

        if let error, error.hasPrefix("github:") {
            refresh()
            note("Minted certificate; GitHub registration failed")
            fail(String(error.dropFirst("github:".count)))
        } else if let error {
            fail(error)
        } else {
            refresh()
            if github { note("Registered ephemeral key on GitHub") }
            if case .valid(let until) = state {
                note("Minted certificate valid until \(Self.timeFormatter.string(from: until))")
            } else {
                note("Minted key, but certificate validity could not be read")
            }
        }
    }

    // MARK: Deletion

    /// Removes the private key, public key and certificate. Synchronous and idempotent so it can run during sleep or logout.
    func deleteKey(reason: String) {
        let fm = FileManager.default
        var removed = 0
        for p in allPaths where fm.fileExists(atPath: p) {
            do {
                try fm.removeItem(atPath: p)
                removed += 1
            } catch {
                logger.error("failed to remove \(p, privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastError = "Failed to remove \(p): \(error.localizedDescription)"
            }
        }
        if removed > 0 { note("Deleted key (\(reason))") }
        refresh()
        // Always clear GitHub as well, whether or not local files were present. Network call, best effort:
        // sleep may cut it short, in which case the next mint or launch sweeps what is left.
        removeFromGitHub()
    }

    /// Whether GitHub cleanup applies: the feature is on, or a key was registered at some point.
    var githubInvolved: Bool { Prefs.bool(Prefs.githubRegister) || Prefs.bool(Prefs.githubEverRegistered) }

    /// Removes every AutoEnclave key from the GitHub account, in the background.
    func removeFromGitHub() {
        guard githubInvolved, GitHub.ghPath != nil else { return }
        Task.detached(priority: .utility) {
            let result = GitHub.unregisterAll()
            await MainActor.run {
                switch result {
                case .success(let n) where n > 0: self.note("Removed ephemeral key from GitHub")
                case .success: break
                case .failure(let e): self.note("GitHub removal failed: \(e.description)")
                }
            }
        }
    }

    /// Removes leftover GitHub keys when nothing valid is on disk (e.g. deleted during sleep with no network).
    func sweepGitHubIfStale() {
        guard Prefs.bool(Prefs.githubRegister) else { return }
        refresh()
        if case .valid = state { return }
        Task.detached(priority: .utility) {
            if case .success(let n) = GitHub.unregisterAll(), n > 0 {
                await MainActor.run { self.note("Removed \(n) stale ephemeral key(s) from GitHub") }
            }
        }
    }

    // MARK: Logging

    func note(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        log.insert(LogEntry(date: Date(), text: text), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }

    private func fail(_ text: String) {
        logger.error("\(text, privacy: .public)")
        lastError = text
        log.insert(LogEntry(date: Date(), text: "Error: " + text), at: 0)
        let alert = NSAlert()
        alert.messageText = "AutoEnclave"
        alert.informativeText = text
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
