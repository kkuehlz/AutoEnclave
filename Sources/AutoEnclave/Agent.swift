import Foundation

/// The SSH agent that holds the CA key. AutoEnclave only ever talks to it over its socket
/// (`ssh-add -L` to list keys, `ssh-keygen -Us` to sign), so any agent works; the known ones just
/// come with a socket path and a name for the UI.
enum Agent: String, CaseIterable, Identifiable {
    case secretive
    case onePassword
    case custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .secretive:   return "Secretive"
        case .onePassword: return "1Password"
        case .custom:      return "Other agent"
        }
    }

    /// Where the agent listens. Nil for `.custom`, whose socket is the `agentSocket` preference.
    var defaultSocket: String? {
        switch self {
        case .secretive:
            return NSHomeDirectory() + "/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
        case .onePassword:
            return NSHomeDirectory() + "/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        case .custom:
            return nil
        }
    }

    /// Shown under the agent picker in General.
    var hint: String {
        switch self {
        case .secretive:
            return "Signing goes through Secretive's agent, so it asks for Touch ID once per mint."
        case .onePassword:
            return "Signing goes through 1Password's SSH agent, so 1Password asks you to authorize once per mint. Turn the agent on in 1Password → Settings → Developer → Use the SSH agent. The CA is any SSH key in your vaults; 1Password offers Private vault keys by default, others via ~/.config/1Password/ssh/agent.toml."
        case .custom:
            return "Any ssh-agent compatible socket. The CA must be a key the agent can sign with."
        }
    }

    /// What to tell the user when the socket is missing or the agent has no keys.
    var notRunningHint: String {
        switch self {
        case .secretive:   return "Is Secretive running?"
        case .onePassword: return "Is 1Password running with its SSH agent turned on?"
        case .custom:      return "Is the agent running?"
        }
    }

    /// Current agent from preferences.
    static var current: Agent {
        Agent(rawValue: Prefs.string(Prefs.agentKind)) ?? .secretive
    }

    /// Expanded socket path for the current agent.
    static var currentSocket: String {
        if let s = current.defaultSocket { return s }
        return (Prefs.string(Prefs.agentSocket) as NSString).expandingTildeInPath
    }

    /// Whether the socket exists on disk right now.
    var socketPresent: Bool {
        guard let s = defaultSocket else { return false }
        return FileManager.default.fileExists(atPath: s)
    }
}
