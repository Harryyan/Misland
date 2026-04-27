import Foundation
import SwiftUI
import MislandCore

/// Bridges `MislandCore.MislandRuntime` into a SwiftUI ObservableObject.
/// Owns runtime lifecycle for the app's lifetime.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var session: SessionState = .init()
    @Published private(set) var allSessions: [SessionState] = []
    @Published private(set) var startupError: String?
    @Published private(set) var isManuallyExpanded: Bool = false
    @Published var soundMuted: Bool {
        didSet { UserDefaults.standard.set(soundMuted, forKey: "misland.sound.muted") }
    }
    @Published var selectedBuddy: BuddySpecies {
        didSet { UserDefaults.standard.set(selectedBuddy.rawValue, forKey: "misland.buddy") }
    }
    @Published private var enabledSounds: Set<String>

    private var runtime: MislandRuntime?
    private var dispose: (() -> Void)?

    init() {
        #if DEBUG
        validateAllBuddyArt()
        #endif
        // Restore persisted prefs.
        self.soundMuted = UserDefaults.standard.bool(forKey: "misland.sound.muted")
        let savedBuddy = UserDefaults.standard.string(forKey: "misland.buddy") ?? BuddySpecies.cat.rawValue
        self.selectedBuddy = BuddySpecies(rawValue: savedBuddy) ?? .cat
        if let saved = UserDefaults.standard.array(forKey: "misland.sound.events") as? [String] {
            self.enabledSounds = Set(saved)
        } else {
            // Default: all events on.
            self.enabledSounds = Set(SoundEvent.allCases.map(\.rawValue))
        }

        do {
            let rt = try MislandRuntime()
            try rt.start()
            self.runtime = rt
            // Observer fires on whatever thread ingest runs on (the socket
            // server's serial queue). Bounce to MainActor for SwiftUI updates.
            self.dispose = rt.store.observe { [weak self] state in
                Task { @MainActor in
                    self?.applyStateUpdate(state)
                }
            }
        } catch {
            self.startupError = "\(error)"
        }
    }

    deinit {
        dispose?()
        runtime?.stop()
    }

    func decide(nonce: String, decision: PermissionDecision) {
        guard let runtime else { return }
        _ = try? runtime.decide(nonce: nonce, decision: decision)
        // Play feedback on user-driven decisions.
        switch decision {
        case .allow:  play(.approvalGranted)
        case .deny:   play(.approvalDenied)
        case .ask:    break
        }
    }

    // MARK: - Hook installer

    func isHookInstalled(bridgePath: String) -> Bool {
        runtime?.installer.isInstalled(bridgePath: bridgePath) ?? false
    }

    func installHooks(bridgePath: String) throws {
        try runtime?.installer.install(bridgePath: bridgePath)
    }

    func uninstallHooks() throws {
        try runtime?.installer.uninstall()
    }

    // MARK: - Sound prefs

    func isSoundEnabled(_ event: SoundEvent) -> Bool {
        enabledSounds.contains(event.rawValue)
    }

    func binding(for event: SoundEvent) -> Binding<Bool> {
        Binding(
            get: { self.isSoundEnabled(event) },
            set: { newValue in
                if newValue { self.enabledSounds.insert(event.rawValue) }
                else        { self.enabledSounds.remove(event.rawValue) }
                UserDefaults.standard.set(Array(self.enabledSounds), forKey: "misland.sound.events")
            }
        )
    }

    func testAllSounds() {
        for event in SoundEvent.allCases where isSoundEnabled(event) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(SoundEvent.allCases.firstIndex(of: event) ?? 0) * 0.6) {
                SoundPlayer.shared.play(event)
            }
        }
    }

    // MARK: - State change → sounds

    private var lastObservedStatus: SessionStatus = .idle
    private var lastObservedPendingNonce: String?

    private func applyStateUpdate(_ new: SessionState) {
        let prev = session
        session = new
        // Refresh full session list whenever any session changes — cheap;
        // SessionStore.sessions is a snapshot copy of the dict values.
        if let runtime { allSessions = runtime.store.sessions }
        // A pending permission auto-collapses the manual session list so
        // the user sees the approval drawer instead.
        if new.pendingPermission != nil { isManuallyExpanded = false }
        triggerSounds(prev: prev, new: new)
    }

    func toggleManualExpansion() {
        guard session.pendingPermission == nil else { return }
        isManuallyExpanded.toggle()
    }

    func collapseManualExpansion() {
        isManuallyExpanded = false
    }

    private func triggerSounds(prev: SessionState, new: SessionState) {
        // Approval needed: pendingPermission appeared (different nonce or transition into approval).
        if let pending = new.pendingPermission, pending.envelopeNonce != lastObservedPendingNonce {
            play(.approvalNeeded)
            lastObservedPendingNonce = pending.envelopeNonce
        } else if new.pendingPermission == nil {
            lastObservedPendingNonce = nil
        }

        // Session start: idle/unknown/ended → any active state.
        let wasInactive = prev.status == .idle || prev.status == .unknown || prev.status == .ended
        let isActive = new.status == .processing || new.status == .runningTool || new.status == .waitingForInput
        if wasInactive && isActive {
            play(.sessionStart)
        }

        // Session complete: any active state → ended.
        if prev.status != .ended && new.status == .ended {
            play(.sessionComplete)
        }
    }

    private func play(_ event: SoundEvent) {
        guard !soundMuted, isSoundEnabled(event) else { return }
        SoundPlayer.shared.play(event)
    }
}

extension SessionStatus {
    var menuBarIconName: String {
        switch self {
        case .idle:               return "circle.dashed"
        case .processing:         return "circle.fill"
        case .runningTool:        return "play.circle.fill"
        case .waitingForApproval: return "exclamationmark.triangle.fill"
        case .waitingForInput:    return "checkmark.circle.fill"
        case .compacting:         return "arrow.triangle.2.circlepath"
        case .ended:              return "stop.circle"
        case .notification:       return "bell.fill"
        case .unknown:             return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .idle, .unknown:     return .secondary
        case .processing, .runningTool: return .cyan
        case .waitingForApproval: return .orange
        case .waitingForInput, .ended:  return .green
        case .compacting:         return .purple
        case .notification:       return .yellow
        }
    }
}
