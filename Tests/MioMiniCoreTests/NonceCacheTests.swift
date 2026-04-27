import XCTest
@testable import MioMiniCore

final class NonceCacheTests: XCTestCase {
    func testFirstUseAccepted() {
        let c = NonceCache()
        XCTAssertTrue(c.consume("abc"))
    }

    func testReplayRejected() {
        let c = NonceCache()
        XCTAssertTrue(c.consume("abc"))
        XCTAssertFalse(c.consume("abc"))
        XCTAssertFalse(c.consume("abc"))
    }

    func testExpiredNonceCanBeReusedAfterTTL() {
        let c = NonceCache(ttl: 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(c.consume("abc", now: t0))
        XCTAssertFalse(c.consume("abc", now: t0.addingTimeInterval(30)))
        XCTAssertTrue(c.consume("abc", now: t0.addingTimeInterval(120)),
                      "after TTL the nonce should be evictable and re-acceptable")
    }

    func testDifferentNoncesIndependent() {
        let c = NonceCache()
        XCTAssertTrue(c.consume("a"))
        XCTAssertTrue(c.consume("b"))
        XCTAssertTrue(c.consume("c"))
        XCTAssertFalse(c.consume("a"))
    }

    func testMaxSizeForcesShrink() {
        let c = NonceCache(ttl: 3600, maxSize: 10)
        for i in 0..<20 {
            _ = c.consume("n\(i)")
        }
        XCTAssertLessThanOrEqual(c.count, 10, "cache must enforce max size")
    }

    func testThreadSafety() {
        let c = NonceCache()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        var firstSeen = 0
        let lock = NSLock()
        for i in 0..<1000 {
            group.enter()
            queue.async {
                let ok = c.consume("n\(i % 100)")
                if ok { lock.lock(); firstSeen += 1; lock.unlock() }
                group.leave()
            }
        }
        group.wait()
        // Of 1000 attempts on 100 nonces, exactly 100 should be accepted.
        XCTAssertEqual(firstSeen, 100)
    }
}
