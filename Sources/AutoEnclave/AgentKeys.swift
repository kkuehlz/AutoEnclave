import Foundation

/// A public key offered by the SSH agent (Secretive).
struct AgentKey: Identifiable, Hashable {
    let line: String          // full "type base64 comment" line, as in authorized_keys
    let fingerprint: String   // SHA256:…
    let type: String          // e.g. ECDSA, ED25519
    var id: String { line }
    var label: String { "\(type) \(fingerprint)" }
}

struct AgentError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

enum AgentKeys {
    /// Lists keys in the agent at `socket`. `ssh-add -L` and `ssh-add -l` return keys in the same order.
    static func list(socket: String) -> Result<[AgentKey], AgentError> {
        let env = ["SSH_AUTH_SOCK": socket]
        let full = Shell.run("/usr/bin/ssh-add", ["-L"], env: env)
        guard full.ok else { return .failure(AgentError("ssh-add failed: \(full.message)")) }
        let lines = full.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if lines.isEmpty { return .success([]) }

        let short = Shell.run("/usr/bin/ssh-add", ["-l"], env: env)
        let fps = short.stdout.split(separator: "\n").map { line -> (String, String) in
            // "256 SHA256:xxxx comment (ECDSA)"
            let parts = line.split(separator: " ").map(String.init)
            let fp = parts.count > 1 ? parts[1] : "?"
            let type = parts.last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")) } ?? "?"
            return (fp, type)
        }
        let keys = lines.enumerated().map { i, line -> AgentKey in
            let (fp, type) = i < fps.count ? fps[i] : ("?", "?")
            return AgentKey(line: line, fingerprint: fp, type: type)
        }
        return .success(keys)
    }
}
