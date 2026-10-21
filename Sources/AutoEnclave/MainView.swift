import SwiftUI
import ServiceManagement

struct MainView: View {
    var body: some View {
        TabView {
            CertificateTab().tabItem { Label("Certificate", systemImage: "key") }
            GeneralTab().tabItem { Label("General", systemImage: "gear") }
            TriggersTab().tabItem { Label("Triggers", systemImage: "bolt") }
            GitHubTab().tabItem { Label("GitHub", systemImage: "arrow.triangle.branch") }
            ActivityTab().tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 600)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - Certificate

struct CertificateTab: View {
    @EnvironmentObject private var keys: KeyManager
    @AppStorage(Prefs.keyPath) private var keyPath = "~/.ssh/ephemeral_enclave"
    @AppStorage(Prefs.principals) private var principals = NSUserName()
    @AppStorage(Prefs.caKeyLine) private var caLine = ""

    var body: some View {
        Form {
            Section("Ephemeral certificate") {
                LabeledContent("Status", value: keys.statusLine)
                if case .valid(let until) = keys.state {
                    LabeledContent("Expires", value: Self.full.string(from: until))
                }
                LabeledContent("Key file", value: keyPath)
                HStack {
                    if case .valid = keys.state {
                        Button("Revoke", role: .destructive) { keys.deleteKey(reason: "revoked manually") }
                    } else {
                        Button(keys.busy ? "Minting…" : "Mint") {
                            Task {
                                await keys.mint()
                                bringWindowForward()   // Secretive's prompt took focus; come back on top
                            }
                        }
                        .disabled(keys.busy)
                        .keyboardShortcut(.defaultAction)
                        if keys.state.isPresent {
                            Button("Remove stale key") { keys.deleteKey(reason: "stale key removed manually") }
                        }
                    }
                }
                Text("Revoking deletes the throwaway key and certificate. Minting generates a new key and asks Secretive to sign it once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Add this line to ~/.ssh/authorized_keys on each host")
                    .font(.headline)
                CopyableText(text: authorizedKeysLine, singleLine: true)
                Text("Click to copy. It is the Secretive public key marked as a certificate authority, deployed like any other key. It makes sshd accept any certificate that key signs for this account. Do not put the certificate itself on the host; it is only used by ssh on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Add this to ~/.ssh/config on this Mac, for the hosts that have the line above")
                    .font(.headline)
                CopyableText(text: sshConfigSnippet)
                Text("Click to copy, then edit the Host patterns. IdentitiesOnly is what stops ssh from offering Secretive's key first; without it the agent key is tried before the certificate. IdentityAgent is not needed for these hosts. For hosts behind a bastion use ProxyJump rather than ForwardAgent: forwarding carries the agent (Secretive), not this key. AutoEnclave never edits this file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { keys.refresh() }
    }

    private var sshConfigSnippet: String {
        """
        Host vin-008 *.example.com
            IdentityFile \(keyPath)
            IdentitiesOnly yes
            # Multiple hops: each leg authenticates from this Mac with the certificate.
            # ProxyJump bastion.example.com
        """
    }

    private var authorizedKeysLine: String {
        let key = caLine.isEmpty ? "<choose the Secretive key in General first>" : caLine
        return "cert-authority,principals=\"\(principals)\" \(key)"
    }

    private func bringWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "AutoEnclave" }?.makeKeyAndOrderFront(nil)
    }

    private static let full: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

// MARK: - General

struct GeneralTab: View {
    @AppStorage(Prefs.keyPath) private var keyPath = "~/.ssh/ephemeral_enclave"
    @AppStorage(Prefs.caPublicKeyPath) private var caPath = "~/.ssh/secretive-ca.pub"
    @AppStorage(Prefs.certIdentity) private var identity = NSUserName()
    @AppStorage(Prefs.principals) private var principals = NSUserName()
    @AppStorage(Prefs.validityHours) private var hours = 10
    @AppStorage(Prefs.agentSocket) private var socket = Prefs.defaultAgentSocket
    @EnvironmentObject private var keys: KeyManager

    var body: some View {
        Form {
            Section("Throwaway key") {
                TextField("Private key path", text: $keyPath)
                    .onSubmit { keys.refresh() }
                Text("The certificate is written next to it as <path>-cert.pub. Point your SSH config at this file with IdentityFile and IdentitiesOnly yes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Certificate authority") {
                CAKeyPicker()
                TextField("CA public key path", text: $caPath)
                TextField("Key ID (-I)", text: $identity)
                TextField("Principals (-n, comma separated)", text: $principals)
                Stepper("Validity: \(hours) hours", value: $hours, in: 1...168)
            }
            Section("Agent") {
                TextField("SSH agent socket", text: $socket)
                Text("Secretive's socket. Signing goes through the agent, so Secretive asks for Touch ID once per mint.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LaunchAtLoginToggle()
            }
        }
        .formStyle(.grouped)
        .padding(.bottom)
    }
}

// MARK: - GitHub

struct GitHubTab: View {
    @AppStorage(Prefs.githubRegister) private var enabled = false
    @AppStorage(Prefs.keyPath) private var keyPath = "~/.ssh/ephemeral_enclave"
    @EnvironmentObject private var keys: KeyManager
    @State private var scopeOK: Bool? = nil
    @State private var granting = false
    @State private var code: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Use the ephemeral key for GitHub", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on { ensureScope() } else { message = nil; code = nil }
                    }
                Text("GitHub doesn't accept certificates on personal accounts, so instead AutoEnclave adds the throwaway public key to your account on each mint and removes it on revoke, through the gh CLI. Pushes and pulls over SSH then work without Secretive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if enabled {
                Section("1. Let gh manage your keys") {
                    HStack {
                        switch scopeOK {
                        case .some(true):
                            Label("gh can manage your keys", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .some(false):
                            Label("gh needs the admin:public_key scope", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        case .none:
                            Label("Checking gh…", systemImage: "clock")
                        }
                        Spacer()
                        if scopeOK == false {
                            Button(granting ? "Waiting for approval in browser…" : "Grant in browser") { grant() }
                                .disabled(granting)
                        }
                    }
                    if let code {
                        HStack {
                            Text("One-time code").font(.caption)
                            CopyableText(text: code, singleLine: true).frame(maxWidth: 140)
                            Text("Already on your clipboard. Paste it into the GitHub page that opened and approve.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.red) }
                    if GitHub.ghPath == nil {
                        Text("gh not found. Install with: brew install gh").font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    Text("2. Add this to ~/.ssh/config")
                        .font(.headline)
                    CopyableText(text: "Host github.com\n    IdentityFile \(keyPath)\n    IdentitiesOnly yes")
                    Text("Click to copy. Then `ssh -T git@github.com` should greet you with no Touch ID.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if enabled { ensureScope() } }
    }

    private func ensureScope() {
        scopeOK = nil
        Task.detached {
            let ok = GitHub.hasScope()
            await MainActor.run { scopeOK = ok }
        }
    }

    private func grant() {
        granting = true; code = nil; message = nil
        Task.detached {
            let result = GitHub.grantScope { c in
                Task { @MainActor in
                    code = c
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c, forType: .string)
                    NSWorkspace.shared.open(GitHub.deviceURL)
                }
            }
            await MainActor.run {
                granting = false
                switch result {
                case .success:
                    code = nil; scopeOK = true; message = nil
                    keys.note("GitHub: admin:public_key scope granted")
                    NSApp.activate(ignoringOtherApps: true)
                    if case .valid = keys.state {
                        // Key already on disk: register it now rather than waiting for the next mint.
                        let pub = keys.publicKeyPath
                        Task.detached {
                            let r = GitHub.register(publicKeyPath: pub)
                            await MainActor.run {
                                if case .failure(let e) = r { message = e.description } else { keys.note("Registered ephemeral key on GitHub") }
                            }
                        }
                    }
                case .failure(let e):
                    message = e.description
                }
            }
        }
    }
}

struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Toggle("Launch at login", isOn: $enabled)
            .onChange(of: enabled) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        Text("Keeps the deletion triggers armed from login onward. Works best with the app in /Applications (make install).")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Triggers

struct TriggersTab: View {
    @AppStorage(Prefs.deleteOnSleep) private var onSleep = true
    @AppStorage(Prefs.deleteOnScreenLock) private var onLock = true
    @AppStorage(Prefs.deleteOnScreensaver) private var onSaver = false
    @AppStorage(Prefs.deleteOnLogout) private var onLogout = true
    @AppStorage(Prefs.deleteOnSessionSwitch) private var onSwitch = true
    @AppStorage(Prefs.deleteOnQuit) private var onQuit = false
    @AppStorage(Prefs.deleteOnExpiry) private var onExpiry = true
    @AppStorage(Prefs.deleteOnIdle) private var onIdle = false
    @AppStorage(Prefs.idleMinutes) private var idleMinutes = 30


    var body: some View {
        Form {
            Section("Delete the key when…") {
                Toggle("The Mac goes to sleep (including lid close)", isOn: $onSleep)
                Toggle("The screen locks", isOn: $onLock)
                Toggle("The screensaver starts", isOn: $onSaver)
                Toggle("You log out, restart or shut down", isOn: $onLogout)
                Toggle("Another user's session becomes active", isOn: $onSwitch)
                Toggle("The certificate expires", isOn: $onExpiry)
                Toggle("AutoEnclave quits", isOn: $onQuit)
                HStack {
                    Toggle("No keyboard or mouse input for", isOn: $onIdle)
                    Stepper("\(idleMinutes) min", value: $idleMinutes, in: 1...720)
                        .disabled(!onIdle)
                }
            }
            Section {
                Text("Minting is always manual: the Mint button in the Certificate tab, one Touch ID prompt. Revocation happens automatically on the events above, or with the Revoke button.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Monospaced text that copies itself to the clipboard when clicked. Pointer cursor and highlight on hover,
/// nothing else changes. Implemented in AppKit because SwiftUI's grouped Form on macOS ignores line limits,
/// swallows tap gestures and resets the cursor for text inside its rows.
struct CopyableText: NSViewRepresentable {
    let text: String
    var singleLine: Bool = false

    func makeNSView(context: Context) -> CopyableTextView { CopyableTextView(text: text, singleLine: singleLine) }
    func updateNSView(_ view: CopyableTextView, context: Context) { view.setText(text) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CopyableTextView, context: Context) -> CGSize? {
        view.preferredSize(forWidth: proposal.width)
    }
}

final class CopyableTextView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let singleLine: Bool
    private var hovering = false { didSet { needsDisplay = true } }
    private static let inset: CGFloat = 6

    init(text: String, singleLine: Bool) {
        self.singleLine = singleLine
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.lineBreakMode = singleLine ? .byTruncatingMiddle : .byWordWrapping
        label.maximumNumberOfLines = singleLine ? 1 : 0
        label.cell?.truncatesLastVisibleLine = singleLine
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        setText(text)
        toolTip = "Click to copy"
    }
    required init?(coder: NSCoder) { fatalError() }

    func setText(_ text: String) {
        let t = text.trimmingCharacters(in: .newlines)
        if label.stringValue != t { label.stringValue = t; invalidateIntrinsicContentSize(); needsLayout = true }
    }

    func preferredSize(forWidth width: CGFloat?) -> CGSize {
        let w = width ?? 400
        let textWidth = max(10, w - 2 * Self.inset)
        let h: CGFloat
        if singleLine {
            h = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000)).height
        } else {
            label.preferredMaxLayoutWidth = textWidth
            h = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height
        }
        return CGSize(width: w, height: h + 2 * Self.inset)
    }

    override func layout() {
        super.layout()
        label.preferredMaxLayoutWidth = bounds.width - 2 * Self.inset
        label.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = hovering ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.labelColor.withAlphaComponent(0.05)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    // Hover + cursor
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    // SwiftUI's hosting view keeps resetting the cursor to the arrow, so re-assert the pointer on every move inside the view.
    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.pointingHand.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // Click = copy. Take the event ourselves so the label never sees it.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(label.stringValue, forType: .string)
        bounce()
    }

    /// Quick vertical bounce to acknowledge the copy without changing any text.
    private func bounce() {
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.y")
        anim.values = [0, 5, -3, 1, 0]        // layer y is flipped relative to the view: positive is up
        anim.keyTimes = [0, 0.3, 0.6, 0.85, 1]
        anim.duration = 0.35
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(anim, forKey: "bounce")
    }
}

// MARK: - Activity

struct ActivityTab: View {
    @EnvironmentObject private var keys: KeyManager
    private static let f: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .medium; return f
    }()

    var body: some View {
        List(keys.log) { entry in
            HStack(alignment: .top) {
                Text(Self.f.string(from: entry.date)).foregroundStyle(.secondary).font(.caption)
                Text(entry.text).font(.caption)
            }
        }
        .frame(minHeight: 300)
        .overlay {
            if keys.log.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
        }
    }
}

// MARK: - CA key picker

/// Dropdown of keys currently in Secretive. The chosen key is remembered and used as the CA for every mint.
struct CAKeyPicker: View {
    @AppStorage(Prefs.caKeyLine) private var caLine = ""
    @AppStorage(Prefs.agentSocket) private var socket = Prefs.defaultAgentSocket
    @State private var keys: [AgentKey] = []
    @State private var error: String?

    var body: some View {
        Group {
        HStack {
            Picker("Secretive key", selection: $caLine) {
                Text("None").tag("")
                ForEach(keys) { Text($0.label).tag($0.line) }
                if !caLine.isEmpty && !keys.contains(where: { $0.line == caLine }) {
                    Text("Chosen key (not currently in Secretive)").tag(caLine)
                }
            }
            Button("Refresh") { load() }
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if keys.isEmpty {
            Text("No keys found in Secretive. Is it running?").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Fingerprints match what Secretive shows for each key.").font(.caption).foregroundStyle(.secondary)
        }
        }
        .onAppear { load() }
    }

    private func load() {
        switch AgentKeys.list(socket: (socket as NSString).expandingTildeInPath) {
        case .success(let k):
            keys = k; error = nil
            if caLine.isEmpty, k.count == 1 { caLine = k[0].line }   // only one key: it's the CA
        case .failure(let e): keys = []; error = e.description
        }
    }
}
