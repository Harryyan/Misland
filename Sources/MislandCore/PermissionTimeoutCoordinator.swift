import Foundation

/// Enforces PRD §6 SEC-5: every PermissionRequest must be either explicitly
/// resolved by the user or auto-denied after `timeout` seconds. Default 30 s,
/// configurable 10–300 s by the user.
///
/// Multi-session aware: every session that holds a pendingPermission gets its
/// own timer keyed by the envelope nonce. Resolving one session's permission
/// (Allow/Deny or any state transition) cancels only that session's timer;
/// other sessions' permissions continue counting down independently.
///
/// Wiring:
/// ```
///   SessionStore.observe ──► PermissionTimeoutCoordinator
///                              │
///                              ├─ for each pending nonce in store.sessions:
///                              │     if no timer armed → arm one
///                              ├─ for each armed timer with no matching pending:
///                              │     cancel it (resolved by user or session ended)
///                              └─ on timer fire: respond(nonce, .deny, "timeout")
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
    /// Per-nonce timers. A pending permission's nonce maps to its 30s timer.
    /// Resolving the permission (or the whole session ending) cancels the
    /// matching entry; only the orphaned timers ever fire `.deny`.
    private var timers: [String: DispatchSourceTimer] = [:]
    private var dispose: (() -> Void)?

    public init(
        timeout: TimeInterval = 30,
        store: SessionStore,
        respond: @escaping Responder,
        queue: DispatchQueue = DispatchQueue(label: "chat.mio.misland.timeout")
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
        let dispose = store.observe { [weak self] _ in
            // We don't actually need the active-session payload — we always
            // re-scan the full sessions list to find pending permissions
            // across every session, not just the surfaced one.
            self?.reconcileTimers()
        }
        lock.lock()
        self.dispose = dispose
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let d = self.dispose
        let snapshot = self.timers
        self.dispose = nil
        self.timers.removeAll()
        lock.unlock()
        d?()
        for (_, timer) in snapshot { timer.cancel() }
    }

    // MARK: - Test / diagnostic surface

    /// True if at least one timer is armed.
    public var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return !timers.isEmpty
    }

    /// All currently armed nonces. Test/diagnostic.
    public var armedNonces: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(timers.keys)
    }

    /// Backwards-compat: any one armed nonce. Keep for existing single-session tests.
    public var armedNonce: String? {
        lock.lock(); defer { lock.unlock() }
        return timers.keys.first
    }

    public var armedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return timers.count
    }

    // MARK: - Internals

    /// Compute the set of currently-pending nonces across every session and
    /// align our timer dict with that set:
    ///   - any timer not in the pending set is canceled (resolved/ended)
    ///   - any pending nonce not in the timer dict gets a new timer
    private func reconcileTimers() {
        guard let store else { return }
        let pendingNonces = Set(
            store.sessions.compactMap { $0.pendingPermission?.envelopeNonce }
        )

        // Gather scheduling work under the lock; resume() outside.
        var newlyArmed: [(String, DispatchSourceTimer)] = []
        var staleTimers: [DispatchSourceTimer] = []

        lock.lock()
        // Cancel + remove stale entries.
        for (nonce, timer) in timers where !pendingNonces.contains(nonce) {
            staleTimers.append(timer)
            timers.removeValue(forKey: nonce)
        }
        // Arm new entries.
        for nonce in pendingNonces where timers[nonce] == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                self?.fireTimeout(for: nonce)
            }
            timers[nonce] = timer
            newlyArmed.append((nonce, timer))
        }
        lock.unlock()

        for t in staleTimers { t.cancel() }
        for (_, t) in newlyArmed { t.resume() }
    }

    private func fireTimeout(for nonce: String) {
        let shouldFire: Bool = {
            lock.lock(); defer { lock.unlock() }
            // Re-check: the permission may have been resolved between the
            // timer being scheduled and the queue actually running its
            // event handler.
            guard timers.removeValue(forKey: nonce) != nil else { return false }
            return true
        }()
        guard shouldFire else { return }
        respond(nonce, .deny, "timeout")
    }
}
