import AppKit
import SwiftUI

/// Owns AppState and the floating notch panel for the entire app lifetime.
///
/// Why AppDelegate owns AppState (rather than @StateObject in the App body):
/// the panel needs to be created at `applicationDidFinishLaunching` so it
/// shows up immediately on launch — before the user has opened any window.
/// If we put @StateObject in the App body and tried to hand it to the
/// delegate later, the delegate would have to wait for a Window scene's
/// `.onAppear`, which never fires unless the user opens that window.
@MainActor
final class MislandAppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var panelController: NotchPanelController?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.spinUpPanel() }
    }

    private func spinUpPanel() {
        guard panelController == nil else { return }
        let controller = NotchPanelController(appState: appState)
        controller.show()
        self.panelController = controller
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // LSUIElement = true means we have no dock icon; closing the Settings
        // window must NOT quit the app.
        false
    }
}
