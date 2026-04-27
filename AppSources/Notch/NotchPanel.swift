import AppKit

/// Borderless floating panel that sits at the screen's top edge, anchored
/// around the MacBook notch. Designed to be always visible (across spaces and
/// fullscreen apps) without ever stealing focus from the active app.
///
/// Key window-server behaviors:
/// - `level = .statusBar + 1` — above ordinary windows AND above fullscreen
///   apps' content (statusBar level is what menu bar uses).
/// - `collectionBehavior` — joins every space and overlays fullscreen.
/// - `canBecomeKey/canBecomeMain = false` — clicking the panel doesn't deactivate
///   the user's actual app. Buttons inside still receive clicks via responder
///   chain because we override `acceptsMouseMovedEvents` and the SwiftUI host
///   handles its own hit testing.
/// - `isOpaque = false`, `backgroundColor = .clear` — the SwiftUI content draws
///   the rounded pill shape; the rest is transparent.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.acceptsMouseMovedEvents = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
    }

    // We never want to be the key window — keeping focus on the user's app
    // is critical so typing in their terminal is uninterrupted by clicks
    // on the panel.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
