import Foundation

/// In-memory state for **all** Claude/Gemini sessions known to the runtime.
///
/// SessionStore is the consumer end of the pipeline:
/// `bridge → socket → server.verify → SessionStore.ingest → state`.
///
/// Each Claude Code (or Gemini activity stream) gets a slot keyed by its
/// `session_id`. The store also computes an `active` session — the one to
/// surface in the collapsed notch bar — using these tiebreakers, in order:
///   1. any session with a pending permission (most pressing)
///   2. the most recently updated session
///
/// Implemented as a sync class (NSLock-protected) rather than an actor so the
/// socket server can ingest from its sync POSIX handler thread without an
/// actor-bridging Task. UI subscribers get notified through `observe()`
/// callbacks fired on the same thread that calls `ingest`.
public final class SessionStore: @unchecked Sendable {
    public typealias Observer = (SessionState) -> Void

    private let lock = NSLock()
    private var sessionsByID: [String: SessionState] = [:]
    private var observers: [UUID: Observer] = [:]

    public init(initial: SessionState = .init()) {
        if let id = initial.sessionId {
            sessionsByID[id] = initial
        }
    }

    // MARK: - Public state accessors

    /// All known sessions, sorted most-recent first.
    public var sessions: [SessionState] {
        lock.lock(); defer { lock.unlock() }
        return sortedLocked()
    }

    /// The session to surface in the collapsed bar:
    /// pending permission > most recently updated > nil.
    public var active: SessionState? {
        lock.lock(); defer { lock.unlock() }
        return computeActiveLocked()
    }

    /// Backwards-compat: returns the active session, or an empty placeholder.
    /// Existing tests pre-multi-session can call this; new code should prefer
    /// `active` (optional) or `sessions` (collection).
    public func snapshot() -> SessionState {
        active ?? SessionState()
    }

    /// Test-friendly alias of `snapshot()`.
    public var state: SessionState { snapshot() }

    // MARK: - Ingest

    /// Apply a normalized payload (the same dict the bridge sends through the
    /// socket envelope's `payload` field). The envelope's nonce is captured so
    /// the UI can later route a permission decision back through the socket
    /// addressed at this exact request.
    ///
    /// Multi-session semantics: each unique `session_id` gets its own slot;
    /// ingests update only their own slot — no cross-session clobbering.
    ///
    /// Source priority preserved per-session: a `gemini_cli` payload that
    /// arrives at a session whose existing entry came from `claude_code`
    /// AND has a pending permission is dropped (defense in depth — Gemini
    /// shouldn't be able to clear Claude's prompt). In practice Gemini and
    /// Claude use disjoint session IDs ("gemini-active" vs Claude's UUIDs)
    /// so this branch rarely fires.
    @discardableResult
    public func ingest(payload: [String: Any], envelopeNonce: String, now: Date = Date()) -> SessionState {
        let (active, observersCopy) = withLock { () -> (SessionState, [Observer]) in
            let id = (payload["session_id"] as? String) ?? "default"
            let source = (payload["source"] as? String) ?? "claude_code"

            // Cross-source guard: refuse to let Gemini clobber a Claude
            // session that is mid-permission. (Same-id Gemini ingest on a
            // Claude session is unusual but possible if the user sets
            // MISLAND_GEMINI_DIR pointing at a Claude data dir.)
            if let existing = sessionsByID[id],
               source == "gemini_cli",
               existing.source == "claude_code",
               existing.pendingPermission != nil {
                return (computeActiveLocked() ?? SessionState(), [])
            }

            var entry = sessionsByID[id] ?? SessionState(sessionId: id)
            let status = (payload["status"] as? String) ?? "unknown"
            entry.status = SessionStatus(rawValue: status) ?? .unknown
            entry.source = source
            entry.sessionId = id
            entry.cwd = payload["cwd"] as? String ?? entry.cwd
            entry.tool = payload["tool"] as? String
            entry.lastUpdate = now

            switch entry.status {
            case .waitingForApproval:
                entry.pendingPermission = PendingPermission(
                    toolUseId: (payload["tool_use_id"] as? String) ?? "",
                    tool: (payload["tool"] as? String) ?? "",
                    toolInputJSON: payload["tool_input_json"] as? String,
                    envelopeNonce: envelopeNonce,
                    receivedAt: now
                )
            default:
                // Any non-approval transition on this session cancels its pending.
                entry.pendingPermission = nil
            }

            sessionsByID[id] = entry
            let active = computeActiveLocked() ?? entry
            return (active, Array(observers.values))
        }
        for cb in observersCopy { cb(active) }
        return active
    }

    // MARK: - Observation

    /// Subscribe to state changes. The callback fires with the **active**
    /// session whenever any session updates. For multi-session UI use
    /// `sessions` directly inside the callback.
    public func observe(_ cb: @escaping Observer) -> () -> Void {
        let id = UUID()
        let snap: SessionState = withLock {
            observers[id] = cb
            return computeActiveLocked() ?? SessionState()
        }
        cb(snap)
        return { [weak self] in
            guard let self else { return }
            _ = self.withLock { self.observers.removeValue(forKey: id) }
        }
    }

    // MARK: - Internals

    private func computeActiveLocked() -> SessionState? {
        // Pending permission takes priority; among those pick the oldest
        // (FIFO — fairer than letting newer requests jump the queue).
        if let pending = sessionsByID.values
            .filter({ $0.pendingPermission != nil })
            .min(by: { ($0.pendingPermission?.receivedAt ?? .distantFuture) <
                       ($1.pendingPermission?.receivedAt ?? .distantFuture) }) {
            return pending
        }
        return sessionsByID.values.max(by: { $0.lastUpdate < $1.lastUpdate })
    }

    private func sortedLocked() -> [SessionState] {
        sessionsByID.values.sorted { $0.lastUpdate > $1.lastUpdate }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

public struct SessionState: Sendable, Equatable {
    public var status: SessionStatus
    public var sessionId: String?
    public var cwd: String?
    public var tool: String?
    /// Identifier of the agent driving the current state. `claude_code` or
    /// `gemini_cli` in v1. Drives the agent badge in the UI.
    public var source: String?
    public var lastUpdate: Date
    public var pendingPermission: PendingPermission?

    public init(
        status: SessionStatus = .idle,
        sessionId: String? = nil,
        cwd: String? = nil,
        tool: String? = nil,
        source: String? = nil,
        lastUpdate: Date = Date(timeIntervalSince1970: 0),
        pendingPermission: PendingPermission? = nil
    ) {
        self.status = status
        self.sessionId = sessionId
        self.cwd = cwd
        self.tool = tool
        self.source = source
        self.lastUpdate = lastUpdate
        self.pendingPermission = pendingPermission
    }
}

public enum SessionStatus: String, Sendable, Equatable {
    case idle
    case processing
    case runningTool = "running_tool"
    case waitingForApproval = "waiting_for_approval"
    case waitingForInput = "waiting_for_input"
    case compacting
    case ended
    case notification
    case unknown
}

public struct PendingPermission: Sendable, Equatable {
    public let toolUseId: String
    public let tool: String
    public let toolInputJSON: String?
    /// The envelope nonce that delivered this permission request. The UI uses it
    /// when sending the user's decision back so the server can route it to the
    /// correct still-blocked bridge connection.
    public let envelopeNonce: String
    public let receivedAt: Date
}
