import Foundation
import Darwin

/// Server side of the hook socket protocol.
///
/// Lifecycle:
/// 1. `start()` binds an AF_UNIX SOCK_STREAM listener at `socketPath` (mode 0600)
///    and registers a DispatchSourceRead so accept happens off the caller thread.
/// 2. For each accepted connection we enforce: peer UID == our UID; read one line;
///    `SocketEnvelope.verify` (HMAC + freshness); `NonceCache.consume` (replay);
///    `SessionStore.ingest`.
/// 3. Non-permission events: connection is closed immediately.
/// 4. `waiting_for_approval` events: connection is parked in `pendingReplies`
///    keyed by envelope nonce. The UI calls `respond(toNonce:decision:reason:)`
///    later to write a signed reply and close.
/// 5. `stop()` cancels the accept source, closes the listening fd, closes any
///    parked replies (their bridges will then exit silently → fail-open-to-CC),
///    and removes the socket file.
public final class HookSocketServer: @unchecked Sendable {
    public let socketPath: String
    private let key: HMACKey
    private let nonceCache: NonceCache
    private let sessionStore: SessionStore
    private let perConnectionTimeout: TimeInterval

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var stopped = false
    private var pendingReplies: [String: Int32] = [:]

    /// Per-connection serial work queue. Accept events and per-client work
    /// are dispatched here in FIFO order, so SessionStore observes events
    /// in the same order Claude Code emitted them.
    private let workQueue = DispatchQueue(label: "chat.mio.misland.socket")

    public init(
        key: HMACKey,
        sessionStore: SessionStore,
        socketPath: String? = nil,
        nonceCache: NonceCache? = nil,
        perConnectionTimeout: TimeInterval = 5
    ) {
        self.key = key
        self.sessionStore = sessionStore
        self.socketPath = socketPath ?? SecurityPaths.socketPath
        self.nonceCache = nonceCache ?? NonceCache()
        self.perConnectionTimeout = perConnectionTimeout
    }

    deinit { stop() }

    public func start() throws {
        try SecurityPaths.ensureSupportDirectory()
        let fd = try UnixSocket.bindServer(path: socketPath)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: workQueue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler {
            // Source owns the listen fd's lifecycle once registered.
            Darwin.close(fd)
        }
        lock.lock()
        listenFD = fd
        acceptSource = source
        stopped = false
        lock.unlock()
        source.resume()
    }

    public func stop() {
        let (src, pending): (DispatchSourceRead?, [Int32]) = {
            lock.lock(); defer { lock.unlock() }
            stopped = true
            let s = acceptSource
            acceptSource = nil
            listenFD = -1
            let p = Array(pendingReplies.values)
            pendingReplies.removeAll()
            return (s, p)
        }()
        src?.cancel()
        for fd in pending { Darwin.close(fd) }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Number of connections currently parked awaiting a permission decision.
    /// Test/diagnostic only.
    public var pendingReplyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingReplies.count
    }

    /// Send a signed permission decision to the bridge that delivered the
    /// request identified by `nonce`. Returns true if a matching pending
    /// connection existed and the reply was written.
    @discardableResult
    public func respond(toNonce nonce: String, decision: PermissionDecision, reason: String? = nil) throws -> Bool {
        let fd: Int32? = {
            lock.lock(); defer { lock.unlock() }
            return pendingReplies.removeValue(forKey: nonce)
        }()
        guard let fd else { return false }
        defer { Darwin.close(fd) }
        var payload: [String: Any] = ["decision": decision.rawValue]
        if let reason, !reason.isEmpty { payload["reason"] = reason }
        let env = try SocketEnvelope.sign(payload: payload, key: key)
        var line = try env.encode()
        line.append(0x0a)
        try UnixSocket.writeAll(fd: fd, data: line)
        return true
    }

    // MARK: - Internals

    private func acceptOne() {
        let fd: Int32 = {
            lock.lock(); defer { lock.unlock() }
            return listenFD
        }()
        guard fd >= 0 else { return }
        guard let client = UnixSocket.accept(listenFD: fd) else { return }
        // SEC-1 defense in depth: peer must be the same UID. The support dir is
        // 0700 so this should always be true for real clients; a mismatch means
        // the dir was loosened or we hit a kernel oddity. Either way, refuse.
        let myUID = Darwin.getuid()
        if let peer = UnixSocket.peerUID(fd: client), peer != myUID {
            Darwin.close(client)
            return
        }
        // Apply per-connection read/write timeouts (DoS defense).
        applyTimeouts(fd: client)
        // Hand off to the same serial queue. Each client is fully resolved
        // (or parked) before we accept the next.
        workQueue.async { [weak self] in
            self?.handleClient(fd: client)
        }
    }

    private func applyTimeouts(fd: Int32) {
        var rcv = timeval(tv_sec: Int(perConnectionTimeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv, socklen_t(MemoryLayout<timeval>.size))
        var snd = timeval(tv_sec: Int(perConnectionTimeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handleClient(fd: Int32) {
        do {
            let line = try UnixSocket.readLine(fd: fd)
            let env = try SocketEnvelope.verify(rawJSON: line, key: key)
            // Replay defense.
            guard nonceCache.consume(env.nonce) else {
                Darwin.close(fd)
                return
            }
            // Apply to store. Sync — same thread, FIFO order preserved.
            sessionStore.ingest(payload: env.payload, envelopeNonce: env.nonce)

            if (env.payload["status"] as? String) == SessionStatus.waitingForApproval.rawValue {
                lock.lock()
                pendingReplies[env.nonce] = fd
                lock.unlock()
                // Caller will respond() later; do not close.
            } else {
                Darwin.close(fd)
            }
        } catch {
            Darwin.close(fd)
        }
    }
}

public enum PermissionDecision: String, Sendable, Equatable {
    case allow
    case deny
    case ask  // pass through to Claude Code's native UI
}
