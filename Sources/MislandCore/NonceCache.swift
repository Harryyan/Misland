import Foundation

/// Replay-attack defense.
///
/// Even though every envelope is HMAC-signed, a captured signed envelope
/// could be re-played within the freshness window (`SocketEnvelope.defaultMaxAgeSeconds`,
/// 30 s) to falsely double-fire a state change. The NonceCache makes each nonce
/// single-use within its TTL: the first `consume` returns true, every subsequent
/// `consume` of the same nonce returns false.
///
/// TTL is set slightly above the envelope freshness window so that a nonce we just
/// rejected for staleness is also already evicted here — no leftover memory.
///
/// This is a synchronous, lock-protected class rather than an actor: the socket
/// server is itself sync POSIX I/O, and bridging to an actor across that boundary
/// would require Task + DispatchSemaphore, an antipattern.
public final class NonceCache: @unchecked Sendable {
    public let ttl: TimeInterval
    public let maxSize: Int

    private let lock = NSLock()
    private var seen: [String: Date] = [:]

    public init(ttl: TimeInterval = 60, maxSize: Int = 10_000) {
        precondition(ttl > 0)
        precondition(maxSize > 0)
        self.ttl = ttl
        self.maxSize = maxSize
    }

    /// Returns `true` if this is the first time we've seen `nonce` within TTL,
    /// recording it for future rejection. Returns `false` if it's a replay.
    @discardableResult
    public func consume(_ nonce: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        evictLocked(now: now)
        if seen[nonce] != nil { return false }
        seen[nonce] = now
        if seen.count > maxSize {
            forceShrinkLocked()
        }
        return true
    }

    /// Number of entries currently held. Test/diagnostic only.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return seen.count
    }

    private func evictLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-ttl)
        seen = seen.filter { $0.value > cutoff }
    }

    private func forceShrinkLocked() {
        // Keep newest half. Worst case: a cache flood from a buggy client.
        let target = max(1, maxSize / 2)
        let kept = seen.sorted { $0.value > $1.value }.prefix(target)
        seen = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
