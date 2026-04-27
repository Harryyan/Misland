import SwiftUI
import MioMiniCore

@main
struct MislandApp: App {
    @NSApplicationDelegateAdaptor(MislandAppDelegate.self) private var appDelegate

    var body: some Scene {
        // The notch panel itself isn't a SwiftUI Scene — it's an NSPanel
        // owned by MislandAppDelegate (created on applicationDidFinishLaunching).
        // Only declare scenes here that need the standard SwiftUI window
        // pipeline: the Settings window for Cmd+, / right-click access.
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }

        Window("Misland Settings", id: "settings") {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
