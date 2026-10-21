import SwiftUI

@main
struct AutoEnclaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var keys = KeyManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(keys)
        } label: {
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.menu)

        Window("AutoEnclave", id: "main") {
            MainView().environmentObject(keys)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private var iconName: String {
        switch keys.state {
        case .valid: return "key.fill"
        case .keyOnly, .expired: return "key"
        case .absent: return "key.slash"
        }
    }
}
