import AppKit

/// Handles the quit path. At logout macOS sends every app a Quit Apple event; this is the last
/// reliable chance to remove the key if the will-power-off notification was missed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar agent with no visible window is otherwise a candidate for automatic termination.
        ProcessInfo.processInfo.disableAutomaticTermination("menu bar agent must keep watching session events")
        ProcessInfo.processInfo.disableSuddenTermination()
        Prefs.registerDefaults()
        Prefs.migrate()
        EventMonitor.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = quitReason()
        let sessionEnding = ["logo", "rlgo", "shut", "rest"].contains(reason)   // kAELogOut, kAEReallyLogOut, kAEShutDown, kAERestart
        if (sessionEnding && Prefs.bool(Prefs.deleteOnLogout)) || Prefs.bool(Prefs.deleteOnQuit) {
            KeyManager.shared.deleteKey(reason: sessionEnding ? "session ending" : "app quit")
        }
        return .terminateNow
    }

    /// Four-char code of the kAEQuitReason attribute on the current Quit event, if any.
    private func quitReason() -> String {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return "" }
        let keyQuitReason = fourCC("why?")
        guard let desc = event.attributeDescriptor(forKeyword: keyQuitReason) else { return "" }
        return String(fourCC: desc.enumCodeValue)
    }

    private func fourCC(_ s: String) -> AEKeyword {
        s.utf8.reduce(0) { ($0 << 8) | AEKeyword($1) }
    }
}

private extension String {
    init(fourCC: OSType) {
        let bytes = [24, 16, 8, 0].map { UInt8((fourCC >> $0) & 0xff) }
        self = String(decoding: bytes, as: UTF8.self)
    }
}
