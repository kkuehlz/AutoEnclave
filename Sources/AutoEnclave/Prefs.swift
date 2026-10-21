import Foundation

/// All user-configurable settings, stored in UserDefaults.
/// Views bind to these keys with @AppStorage; non-view code reads them through `Prefs`.
enum Prefs {
    // Paths and certificate parameters
    static let keyPath          = "keyPath"
    static let caPublicKeyPath  = "caPublicKeyPath"
    static let caKeyLine        = "caKeyLine"         // the agent public key chosen as CA (full authorized_keys line)
    static let certIdentity     = "certIdentity"
    static let principals       = "principals"
    static let validityHours    = "validityHours"
    static let agentKind        = "agentKind"         // Agent.rawValue: secretive, onePassword, custom
    static let agentSocket      = "agentSocket"       // only used when agentKind is custom

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

    // GitHub: register the throwaway public key on mint, remove it on revoke (via gh)
    static let githubRegister = "githubRegister"
    static let githubEverRegistered = "githubEverRegistered"   // set once a key has been put on GitHub, so cleanup keeps running even if the toggle is later turned off

    static let defaultAgentSocket = Agent.secretive.defaultSocket!

    private static var registered = false

    static func registerDefaults() {
        guard !registered else { return }
        registered = true
        UserDefaults.standard.register(defaults: [
            keyPath: "~/.ssh/ephemeral_enclave",
            caPublicKeyPath: "~/.ssh/secretive-ca.pub",
            certIdentity: NSUserName(),
            principals: NSUserName(),
            validityHours: 10,
            agentKind: defaultAgentKind().rawValue,
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
            githubRegister: false,
            githubEverRegistered: false,
        ])
    }

    /// First-run choice of agent: Secretive, unless only 1Password's agent socket is present on this Mac.
    private static func defaultAgentKind() -> Agent {
        if !Agent.secretive.socketPresent && Agent.onePassword.socketPresent { return .onePassword }
        return .secretive
    }

    /// One-time migration: builds before the rename stored "~/.ssh/day" as the key path.
    static func migrate() {
        let d = UserDefaults.standard
        // Builds before the agent picker only had a socket path. A non-default path means a custom agent.
        // (object(forKey:) would also see the registered default, so look at what is actually stored.)
        let stored = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "xyz.category.autoenclave") ?? [:]
        if stored[agentKind] == nil, let sock = stored[agentSocket] as? String, !sock.isEmpty {
            let expanded = (sock as NSString).expandingTildeInPath
            if expanded == Agent.secretive.defaultSocket { d.set(Agent.secretive.rawValue, forKey: agentKind) }
            else if expanded == Agent.onePassword.defaultSocket { d.set(Agent.onePassword.rawValue, forKey: agentKind) }
            else { d.set(Agent.custom.rawValue, forKey: agentKind) }
        }
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
    /// Socket of the chosen agent (its fixed path, or the custom path preference).
    static var expandedAgentSocket: String { Agent.currentSocket }
}
