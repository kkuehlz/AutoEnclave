import AppKit
import CoreGraphics
import Foundation

/// Subscribes to macOS session events and translates them into key deletions or mints,
/// according to the user's trigger settings.
@MainActor
final class EventMonitor {
    static let shared = EventMonitor()

    private let workspace = NSWorkspace.shared.notificationCenter
    private let distributed = DistributedNotificationCenter.default()
    private var idleTimer: Timer?
    private var idleFired = false

    private init() {}

    func start() {
        // --- Deletion triggers ---
        observe(workspace, NSWorkspace.willSleepNotification, pref: Prefs.deleteOnSleep) {
            $0.deleteKey(reason: "system sleep")
        }
        observe(workspace, NSWorkspace.willPowerOffNotification, pref: Prefs.deleteOnLogout) {
            $0.deleteKey(reason: "logout or shutdown")
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, pref: Prefs.deleteOnSessionSwitch) {
            $0.deleteKey(reason: "session switched away")
        }
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), pref: Prefs.deleteOnScreenLock) {
            $0.deleteKey(reason: "screen locked")
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart"), pref: Prefs.deleteOnScreensaver) {
            $0.deleteKey(reason: "screensaver started")
        }

        // --- Mint triggers (only when nothing valid is on disk) ---
        observe(workspace, NSWorkspace.didWakeNotification, pref: Prefs.mintOnWake) {
            $0.mintIfNeeded(reason: "wake")
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, pref: Prefs.mintOnSession) {
            $0.mintIfNeeded(reason: "session active")
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), pref: Prefs.mintOnUnlock) {
            $0.mintIfNeeded(reason: "screen unlocked")
        }

        // Idle polling. Cheap, so it just runs every 30 s and checks the pref each time.
        let t = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.checkIdle() }
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t

        KeyManager.shared.sweepGitHubIfStale()
        SSHConfig.sync(force: Prefs.bool(Prefs.sshConfigOverrideAccepted))

        if Prefs.bool(Prefs.mintOnLaunch) {
            // Give the menu bar a moment to appear before the Touch ID prompt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                KeyManager.shared.mintIfNeeded(reason: "launch")
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, pref: String,
                         _ action: @escaping @MainActor (KeyManager) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            guard Prefs.bool(pref) else { return }
            Task { @MainActor in action(KeyManager.shared) }
        }
    }

    private func checkIdle() {
        guard Prefs.bool(Prefs.deleteOnIdle) else { idleFired = false; return }
        let limit = TimeInterval(max(1, Prefs.int(Prefs.idleMinutes)) * 60)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= limit {
            if !idleFired, KeyManager.shared.state.isPresent {
                idleFired = true
                KeyManager.shared.deleteKey(reason: "idle for \(Int(idle / 60)) min")
            }
        } else {
            idleFired = false
        }
    }
}

extension KeyManager {
    /// Mints only when there is no currently valid certificate, so wake/unlock don't cause repeated Touch ID prompts.
    func mintIfNeeded(reason: String) {
        if case .valid = state { return }
        Task { await mint() }
    }
}
