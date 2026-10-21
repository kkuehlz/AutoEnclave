import Foundation

/// All user-configurable settings, stored in UserDefaults.
/// Views bind to these keys with @AppStorage; non-view code reads them through `Prefs`.
enum Prefs {
    // Paths and certificate parameters
    static let keyPath          = "keyPath"
    static let caPublicKeyPath  = "caPublicKeyPath"
    static let caKeyLine        = "caKeyLine"         // the Secretive public key chosen as CA (full authorized_keys line)
    static let certIdentity     = "certIdentity"
    static let principals       = "principals"
    static let validityHours    = "validityHours"
    static let agentSocket      = "agentSocket"

    // Deletion triggers
    static let deleteOnSleep         = "deleteOnSleep"
    static let deleteOnScreenLock    = "deleteOnScreenLock"
    static let deleteOnScreensaver   = "deleteOnScreensaver"
    static let deleteOnLogout        = "deleteOnLogout"
    static let deleteOnSessionSwitch = "deleteOnSessionSwitch"
    static let deleteOnQuit          = "deleteOnQuit"
    static let deleteOnExpiry        = "deleteOnExpiry"
    static let deleteOnIdle          = "deleteOnIdle"
    static let idleMinutes           = "idleMinutes"

    // Mint triggers (only mint when no valid certificate is present)
    static let mintOnLaunch   = "mintOnLaunch"      // app starts, i.e. at login when launch-at-login is on
    static let mintOnWake     = "mintOnWake"
    static let mintOnUnlock   = "mintOnUnlock"
    static let mintOnSession  = "mintOnSession"     // fast-user-switch back to this user

    // GitHub: register the throwaway public key on mint, remove it on revoke (via gh)
    static let githubRegister = "githubRegister"

    // Host patterns (comma separated) that ~/.ssh/config should point at the throwaway key
    static let managedHosts   = "managedHosts"
    static let sshConfigOverrideAccepted = "sshConfigOverrideAccepted"   // user chose "Apply anyway" for conflicts

    static let defaultAgentSocket =
        NSHomeDirectory() + "/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            keyPath: "~/.ssh/ephemeral_enclave",
            caPublicKeyPath: "~/.ssh/secretive-ca.pub",
            certIdentity: NSUserName(),
            principals: NSUserName(),
            validityHours: 10,
            agentSocket: defaultAgentSocket,
            deleteOnSleep: true,
            deleteOnScreenLock: true,
            deleteOnScreensaver: false,
            deleteOnLogout: true,
            deleteOnSessionSwitch: true,
            deleteOnQuit: false,
            deleteOnExpiry: true,
            deleteOnIdle: false,
            idleMinutes: 30,
            mintOnLaunch: true,
            mintOnWake: true,
            mintOnUnlock: true,
            mintOnSession: true,
            githubRegister: false,
            managedHosts: "",
            sshConfigOverrideAccepted: false,
        ])
    }

    /// One-time migration: builds before the rename stored "~/.ssh/day" as the key path.
    static func migrate() {
        let d = UserDefaults.standard
        if d.string(forKey: keyPath) == "~/.ssh/day" {
            let fm = FileManager.default
            let old = ("~/.ssh/day" as NSString).expandingTildeInPath
            let new = ("~/.ssh/ephemeral_enclave" as NSString).expandingTildeInPath
            for suffix in ["", ".pub", "-cert.pub"] where fm.fileExists(atPath: old + suffix) && !fm.fileExists(atPath: new + suffix) {
                try? fm.moveItem(atPath: old + suffix, toPath: new + suffix)
            }
            d.removeObject(forKey: keyPath)
        }
    }

    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func int(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }

    /// Expanded absolute path of the private key.
    static var expandedKeyPath: String { (string(keyPath) as NSString).expandingTildeInPath }
    static var expandedCAPath: String { (string(caPublicKeyPath) as NSString).expandingTildeInPath }
    static var expandedAgentSocket: String { (string(agentSocket) as NSString).expandingTildeInPath }
}
