import XCTest
@testable import MislandCore

final class SessionStoreMultiSessionTests: XCTestCase {
    func testTwoSessionsBothTracked() {
        let store = SessionStore()
        store.ingest(payload: ["status": "processing", "session_id": "s-A", "cwd": "/proj/A"], envelopeNonce: "n1")
        store.ingest(payload: ["status": "running_tool", "session_id": "s-B", "cwd": "/proj/B", "tool": "Bash"], envelopeNonce: "n2")

        XCTAssertEqual(store.sessions.count, 2)
        let ids = Set(store.sessions.compactMap(\.sessionId))
        XCTAssertEqual(ids, ["s-A", "s-B"])
    }

    func testActiveIsMostRecentlyUpdated() {
        let store = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        store.ingest(
            payload: ["status": "processing", "session_id": "old", "cwd": "/old"],
            envelopeNonce: "n1",
            now: t0
        )
        store.ingest(
            payload: ["status": "processing", "session_id": "new", "cwd": "/new"],
            envelopeNonce: "n2",
            now: t0.addingTimeInterval(10)
        )
        XCTAssertEqual(store.active?.sessionId, "new")
    }

    func testActiveIsPendingEvenIfOtherIsNewer() {
        let store = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // s-pending sends an approval first
        store.ingest(
            payload: [
                "status": "waiting_for_approval",
                "session_id": "s-pending",
                "tool": "Bash",
                "tool_use_id": "u-1",
            ],
            envelopeNonce: "approve-1",
            now: t0
        )
        // s-recent then sends a non-approval, MORE RECENT update
        store.ingest(
            payload: ["status": "processing", "session_id": "s-recent"],
            envelopeNonce: "proc-1",
            now: t0.addingTimeInterval(60)
        )
        // active should still be the pending one — pending takes priority
        XCTAssertEqual(store.active?.sessionId, "s-pending")
        XCTAssertNotNil(store.active?.pendingPermission)
    }

    func testPendingResolvedReturnsToMostRecent() {
        let store = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        store.ingest(
            payload: ["status": "waiting_for_approval", "session_id": "s-A", "tool": "Bash", "tool_use_id": "u"],
            envelopeNonce: "n1",
            now: t0
        )
        store.ingest(
            payload: ["status": "processing", "session_id": "s-B"],
            envelopeNonce: "n2",
            now: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(store.active?.sessionId, "s-A")  // pending wins

        // Resolve s-A by sending a non-approval status
        store.ingest(
            payload: ["status": "processing", "session_id": "s-A"],
            envelopeNonce: "n3",
            now: t0.addingTimeInterval(10)
        )
        // Now s-A is most recent (last ingest), so it's still active —
        // but no pending permission anymore.
        XCTAssertEqual(store.active?.sessionId, "s-A")
        XCTAssertNil(store.active?.pendingPermission)
    }

    func testGeminiAndClaudeCoexist() {
        let store = SessionStore()
        store.ingest(
            payload: ["status": "processing", "source": "claude_code", "session_id": "claude-1"],
            envelopeNonce: "c1"
        )
        store.ingest(
            payload: ["status": "processing", "source": "gemini_cli", "session_id": "gemini-active"],
            envelopeNonce: "g1"
        )
        XCTAssertEqual(store.sessions.count, 2)
        let sources = Set(store.sessions.compactMap(\.source))
        XCTAssertEqual(sources, ["claude_code", "gemini_cli"])
    }

    func testGeminiCannotClobberClaudePendingOnSameID() {
        let store = SessionStore()
        // Unusual but possible: same session_id for both sources.
        store.ingest(
            payload: ["status": "waiting_for_approval", "source": "claude_code", "session_id": "shared", "tool": "Bash", "tool_use_id": "u"],
            envelopeNonce: "c-pending"
        )
        store.ingest(
            payload: ["status": "processing", "source": "gemini_cli", "session_id": "shared"],
            envelopeNonce: "g-clobber"
        )
        XCTAssertEqual(store.active?.source, "claude_code")
        XCTAssertNotNil(store.active?.pendingPermission)
    }

    func testSnapshotBackwardsCompatReturnsActive() {
        let store = SessionStore()
        store.ingest(payload: ["status": "processing", "session_id": "s"], envelopeNonce: "n")
        XCTAssertEqual(store.snapshot().status, .processing)
        XCTAssertEqual(store.snapshot().sessionId, "s")
    }

    func testSnapshotEmptyWhenNoSessions() {
        let store = SessionStore()
        XCTAssertEqual(store.snapshot().status, .idle)
        XCTAssertNil(store.active)
    }
}
