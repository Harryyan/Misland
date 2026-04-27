import Foundation

/// Enforces PRD §6 SEC-5: every PermissionRequest must be either explicitly
/// resolved by the user or auto-denied after `timeout` seconds. Default 30 s,
/// configurable 10–300 s by the user.
///
/// Wiring:
/// ```
/// SessionStore.observe ──► PermissionTimeoutCoordinator
///                            │
///                            ├─ on new pendingPermission: arm timer
///                            ├─ on different nonce / no pending: cancel
///                            └─ on timer fire: respond(.deny, "timeout")
/// ```
///
/// The coordinator depends on a generic `Responder` closure rather than holding
/// a `HookSocketServer` directly so tests can drive it without standing up a
/// real socket. In production the closure forwards to `server.respond(...)`.
public final class PermissionTimeoutCoordinator: @unchecked Sendable {
    public typealias Responder = (_ nonce: String, _ decision: PermissionDecision, _ reason: String?) -> Void

    public let timeout: TimeInterval
    private let respond: Responder
    private weak var store: SessionStore?

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var currentTimer: DispatchSourceTimer?
    private var currentNonce: String?
    private var dispose: (() -> Void)?

    public init(
        timeout: TimeInterval = 30,
        store: SessionStore,
        respond: @escaping Responder,
        queue: DispatchQueue = DispatchQueue(label: "chat.mio.miomini.timeout")
    ) {
        precondition(timeout > 0)
        self.timeout = timeout
        self.store = store
        self.respond = respond
        self.queue = queue
    }

    deinit { stop() }

    public func start() {
        guard let store else { return }
        let dispose = store.observe { [weak self] state in
            self?.handleStateChange(state)
        }
        lock.lock()
        self.dispose = dispose
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let d = self.dispose
        let t = self.currentTimer
        self.dispose = nil
        self.currentTimer = nil
        self.currentNonce = nil
        lock.unlock()
        d?()
        t?.cancel()
    }

    /// True if a timer is currently armed. Test/diagnostic.
    public var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentTimer != nil
    }

    public var armedNonce: String? {
        lock.lock(); defer { lock.unlock() }
        return currentNonce
    }

    // MARK: - Internals

    private func handleStateChange(_ state: SessionState) {
        let pending = state.pendingPermission
        lock.lock()
        let prevNonce = currentNonce
        // Same pending as before (or both nil) → no-op. Critical: re-arming on
        // every observation would reset the timer indefinitely and SEC-5 would
        // never fire.
        if pending?.envelopeNonce == prevNonce {
            lock.unlock()
            return
        }
        currentTimer?.cancel()
        currentTimer = nil
        currentNonce = nil
        guard let pending else {
            lock.unlock()
            return
        }
        let nonce = pending.envelopeNonce
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.fireTimeout(for: nonce)
        }
        currentTimer = timer
        currentNonce = nonce
        lock.unlock()
        timer.resume()
    }

    private func fireTimeout(for nonce: String) {
        let shouldFire: Bool = {
            lock.lock(); defer { lock.unlock() }
            // Re-check: the user may have responded between schedule and fire.
            guard currentNonce == nonce else { return false }
            currentNonce = nil
            currentTimer = nil
            return true
        }()
        guard shouldFire else { return }
        respond(nonce, .deny, "timeout")
    }
}
