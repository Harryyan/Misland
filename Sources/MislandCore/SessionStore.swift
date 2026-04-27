import Foundation

/// In-memory state of the single most-active session (v1 spec).
///
/// SessionStore is the consumer end of the pipeline:
/// `bridge → socket → server.verify → SessionStore.ingest → state`.
///
/// Implemented as a sync class (NSLock-protected) rather than an actor so the
/// socket server can ingest from its sync POSIX handler thread without an
/// actor-bridging Task. UI subscribers (W3) get notified through `observe()`
/// callbacks fired on the same thread that calls `ingest`.
public final class SessionStore: @unchecked Sendable {
    public typealias Observer = (SessionState) -> Void

    private let lock = NSLock()
    private var _state: SessionState
    private var observers: [UUID: Observer] = [:]

    public init(initial: SessionState = .init()) {
        _state = initial
    }

    public var state: SessionState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public func snapshot() -> SessionState {
        state
    }

    /// Apply a normalized payload (the same dict the bridge sends through the
    /// socket envelope's `payload` field). The envelope's nonce is captured so
    /// the UI can later route a permission decision back through the socket
    /// addressed at this exact request.
    ///
    /// Source priority: a `gemini_cli` payload is read-only and must NEVER
    /// clobber a Claude pending permission. If a permission is already pending,
    /// gemini ingests are dropped on the floor.
    @discardableResult
    public func ingest(payload: [String: Any], envelopeNonce: String, now: Date = Date()) -> SessionState {
        let (newState, observersCopy) = withLock { () -> (SessionState, [Observer]) in
            let source = (payload["source"] as? String) ?? "claude_code"

            // Read-only sources never override a pending claude permission.
            if source == "gemini_cli" && _state.pendingPermission != nil {
                return (_state, [])
            }

            let status = (payload["status"] as? String) ?? "unknown"
            _state.status = SessionStatus(rawValue: status) ?? .unknown
            _state.source = source
            _state.sessionId = payload["session_id"] as? String ?? _state.sessionId
            _state.cwd = payload["cwd"] as? String ?? _state.cwd
            _state.tool = payload["tool"] as? String
            _state.lastUpdate = now

            switch _state.status {
            case .waitingForApproval:
                _state.pendingPermission = PendingPermission(
                    toolUseId: (payload["tool_use_id"] as? String) ?? "",
                    tool: (payload["tool"] as? String) ?? "",
                    toolInputJSON: payload["tool_input_json"] as? String,
                    envelopeNonce: envelopeNonce,
                    receivedAt: now
                )
            default:
                // Any non-approval transition cancels a pending permission.
                _state.pendingPermission = nil
            }
            return (_state, Array(observers.values))
        }
        for cb in observersCopy { cb(newState) }
        return newState
    }

    /// Subscribe to state changes. The callback fires synchronously on whatever
    /// thread called `ingest`. Returns a disposer that, when called, removes the
    /// observer. The callback is also invoked once with the current snapshot
    /// to give subscribers an immediate baseline.
    public func observe(_ cb: @escaping Observer) -> () -> Void {
        let id = UUID()
        let snap: SessionState = withLock {
            observers[id] = cb
            return _state
        }
        cb(snap)
        return { [weak self] in
            guard let self else { return }
            _ = self.withLock { self.observers.removeValue(forKey: id) }
        }
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
