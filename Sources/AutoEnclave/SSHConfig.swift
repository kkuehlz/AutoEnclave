import Foundation
import SSHConfigKit
import os

/// Owns one marked block at the top of ~/.ssh/config that points chosen hosts at the throwaway key.
/// ssh uses the first matching value for each option, so the block at the top wins for IdentityFile
/// while every other option still comes from the user's own entries below.
enum SSHConfig {
    static let path = NSHomeDirectory() + "/.ssh/config"
    private static let logger = Logger(subsystem: "xyz.category.autoenclave", category: "sshconfig")

    /// Host patterns the block should cover, from settings.
    static var desiredHosts: [String] {
        var hosts = Prefs.string(Prefs.managedHosts)
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map(String.init).filter { !$0.isEmpty }
        if Prefs.bool(Prefs.githubRegister), !hosts.contains("github.com") { hosts.insert("github.com", at: 0) }
        return hosts
    }

    static func block(hosts: [String], keyPath: String) -> String { SSHConfigBlock.render(hosts: hosts, keyPath: keyPath) }
    static func stripBlock(_ text: String) -> String { SSHConfigBlock.strip(text) }

    enum SyncResult: Equatable {
        case unchanged
        case applied
        case conflicts([SSHConfigConflict])
        case failed(String)
    }

    /// Existing settings the block would override, for the hosts in settings.
    static func currentConflicts() -> [SSHConfigConflict] {
        SSHConfigParser.conflicts(in: SSHConfigParser.parse(file: path), managedHosts: desiredHosts)
    }

    /// Rewrites the managed block to match settings, or removes it when no hosts are configured.
    /// Refuses to add hosts whose existing settings it would override unless `force` is set
    /// (removing hosts never needs force).
    @discardableResult
    static func sync(force: Bool = false) -> SyncResult {
        let hosts = desiredHosts
        let keyPath = Prefs.string(Prefs.keyPath)
        let fm = FileManager.default
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let stripped = stripBlock(existing)
        let new = hosts.isEmpty ? stripped : block(hosts: hosts, keyPath: keyPath) + stripped
        if new == existing { return .unchanged }

        if !hosts.isEmpty, !force {
            let conflicts = SSHConfigParser.conflicts(in: SSHConfigParser.parse(text: existing, file: path), managedHosts: hosts)
            if !conflicts.isEmpty {
                logger.notice("not touching ssh config: \(conflicts.count) conflicting setting(s)")
                return .conflicts(conflicts)
            }
        }
        do {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: path), !fm.fileExists(atPath: path + ".autoenclave-backup") {
                try? fm.copyItem(atPath: path, toPath: path + ".autoenclave-backup")   // one-time safety copy
            }
            try new.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            logger.notice("ssh config block now covers: \(hosts.joined(separator: " "), privacy: .public)")
            return .applied
        } catch {
            return .failed("Could not update \(path): \(error.localizedDescription)")
        }
    }

    /// Current block contents as written on disk, for display.
    static func currentBlock() -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return SSHConfigBlock.current(in: text)
    }
}
