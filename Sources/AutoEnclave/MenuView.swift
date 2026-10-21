import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var keys: KeyManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(keys.statusLine)
        Divider()
        // Same one-action-at-a-time rule as the Certificate tab.
        if case .valid = keys.state {
            Button("Revoke Ephemeral Certificate") { keys.deleteKey(reason: "revoked manually") }
                .keyboardShortcut("r")
        } else {
            Button(keys.busy ? "Minting…" : "Mint Ephemeral Certificate") { Task { await keys.mint() } }
                .disabled(keys.busy)
                .keyboardShortcut("m")
            if keys.state.isPresent {
                Button("Remove Stale Key") { keys.deleteKey(reason: "stale key removed manually") }
            }
        }
        Divider()
        Button("Open AutoEnclave") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Button("Quit AutoEnclave") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension KeyManager {
    var statusLine: String {
        switch state {
        case .absent:
            return "No ephemeral certificate"
        case .keyOnly:
            return "Key present, no certificate"
        case .expired(let at):
            return "Certificate expired at \(KeyManager.timeFormatter.string(from: at))"
        case .valid(let until):
            let remaining = max(0, until.timeIntervalSinceNow)
            let h = Int(remaining) / 3600, m = (Int(remaining) % 3600) / 60
            return "Valid until \(KeyManager.timeFormatter.string(from: until)) (\(h)h \(m)m left)"
        }
    }
}
