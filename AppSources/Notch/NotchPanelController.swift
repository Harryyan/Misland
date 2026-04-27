import AppKit
import SwiftUI
import Combine

/// Owns the NotchPanel lifecycle: creates it, parents the SwiftUI content,
/// repositions it on screen changes, and drives collapsed ↔ expanded state
/// transitions in response to AppState (pending permission appears / clears).
@MainActor
final class NotchPanelController {
    private let appState: AppState
    private let panel: NotchPanel
    /// AnyView-erased so we can hand it `NotchView().environmentObject(...)`,
    /// whose actual return type is an opaque `some View` modifier chain.
    private let hostingView: NSHostingView<AnyView>
    private var geometry: NotchGeometry
    private var screenChangeObserver: NSObjectProtocol?
    private var stateCancellable: AnyCancellable?

    private var isExpanded: Bool = false

    init(appState: AppState) {
        self.appState = appState
        self.geometry = NotchGeometry(screen: NotchGeometry.bestScreen())

        let initialFrame = geometry.collapsedFrame()
        self.panel = NotchPanel(contentRect: initialFrame)

        // Build the SwiftUI hosting view AFTER the panel exists so we can
        // hand the panel reference into the view for context-menu actions.
        let view = AnyView(
            NotchView(geometry: geometry).environmentObject(appState)
        )
        self.hostingView = NSHostingView(rootView: view)
        self.hostingView.frame = NSRect(origin: .zero, size: initialFrame.size)
        self.hostingView.autoresizingMask = [.width, .height]

        self.panel.contentView = hostingView
        self.panel.setFrame(initialFrame, display: false)
    }

    func show() {
        panel.orderFrontRegardless()
        observeScreenChanges()
        observeState()
    }

    func hide() {
        panel.orderOut(nil)
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            screenChangeObserver = nil
        }
        stateCancellable = nil
    }

    // MARK: - Observation

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // didChangeScreenParametersNotification fires on the main thread
            // already; the closure body still needs MainActor for our state.
            Task { @MainActor [weak self] in self?.repositionForScreens() }
        }
    }

    private func observeState() {
        // Drive expanded-vs-collapsed off pendingPermission. Combine's @Published
        // stream gives us a clean handoff with main-thread delivery.
        stateCancellable = appState.$session
            .map { $0.pendingPermission != nil }
            .removeDuplicates()
            .sink { [weak self] hasPending in
                self?.setExpanded(hasPending)
            }
    }

    private func repositionForScreens() {
        geometry = NotchGeometry(screen: NotchGeometry.bestScreen())
        applyFrame()
        // Screen changes can also rewrite SwiftUI's environment for safe-area;
        // re-set the root view so NotchView gets the new geometry.
        hostingView.rootView = AnyView(
            NotchView(geometry: geometry).environmentObject(appState)
        )
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        applyFrame(animated: true)
    }

    private func applyFrame(animated: Bool = false) {
        let frame = isExpanded ? geometry.expandedFrame() : geometry.collapsedFrame()
        panel.setFrame(frame, display: true, animate: animated)
    }
}
