import AppKit
import CoreGraphics
import Foundation

/// Subscribes to macOS session events and deletes the throwaway key on the ones the user enabled.
/// Minting is never automatic; it is the Mint button in the app.
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

        // Idle polling. Cheap, so it just runs every 30 s and checks the pref each time.
        let t = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.checkIdle() }
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t

        KeyManager.shared.sweepGitHubIfStale()

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
