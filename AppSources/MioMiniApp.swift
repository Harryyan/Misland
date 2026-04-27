import SwiftUI
import MioMiniCore

@main
struct MioMiniApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
        } label: {
            // Status dot in the menu bar.
            Image(systemName: appState.session.status.menuBarIconName)
                .foregroundStyle(appState.session.status.color)
        }
        .menuBarExtraStyle(.window)

        Window("MioMini Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
