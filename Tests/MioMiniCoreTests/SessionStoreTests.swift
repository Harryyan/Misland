import XCTest
@testable import MioMiniCore

final class SessionStoreTests: XCTestCase {
    func testInitialIdle() {
        let store = SessionStore()
        XCTAssertEqual(store.snapshot().status, .idle)
        XCTAssertNil(store.snapshot().pendingPermission)
    }

    func testIngestProcessing() {
        let store = SessionStore()
        let now = Date()
        store.ingest(
            payload: [
                "status": "processing",
                "session_id": "s-1",
                "cwd": "/u/me",
            ],
            envelopeNonce: "n1",
            now: now
        )
        let s = store.snapshot()
        XCTAssertEqual(s.status, .processing)
        XCTAssertEqual(s.sessionId, "s-1")
        XCTAssertEqual(s.cwd, "/u/me")
        XCTAssertEqual(s.lastUpdate, now)
        XCTAssertNil(s.pendingPermission)
    }

    func testWaitingForApprovalCapturesPending() {
        let store = SessionStore()
        store.ingest(
            payload: [
                "status": "waiting_for_approval",
                "session_id": "s-1",
                "tool": "Bash",
                "tool_use_id": "u-7",
                "tool_input_json": "{\"command\":\"rm -rf /\"}",
            ],
            envelopeNonce: "approve-nonce"
        )
        let p = store.snapshot().pendingPermission
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.tool, "Bash")
        XCTAssertEqual(p?.toolUseId, "u-7")
        XCTAssertEqual(p?.envelopeNonce, "approve-nonce")
        XCTAssertEqual(p?.toolInputJSON, "{\"command\":\"rm -rf /\"}")
    }

    func testNonApprovalClearsPending() {
        let store = SessionStore()
        store.ingest(
            payload: ["status": "waiting_for_approval", "tool_use_id": "u-7", "tool": "Bash"],
            envelopeNonce: "n1"
        )
        XCTAssertNotNil(store.snapshot().pendingPermission)

        store.ingest(payload: ["status": "processing"], envelopeNonce: "n2")
        XCTAssertNil(store.snapshot().pendingPermission)
    }

    func testUnknownStatusFallsBackGracefully() {
        let store = SessionStore()
        store.ingest(payload: ["status": "garbage_status"], envelopeNonce: "n1")
        XCTAssertEqual(store.snapshot().status, .unknown)
    }

    func testObservers() {
        let store = SessionStore()
        var seen: [SessionStatus] = []
        let dispose = store.observe { state in seen.append(state.status) }

        store.ingest(payload: ["status": "processing"], envelopeNonce: "n1")
        store.ingest(payload: ["status": "running_tool"], envelopeNonce: "n2")
        store.ingest(payload: ["status": "ended"], envelopeNonce: "n3")

        // Observer fires once on subscribe + once per ingest.
        XCTAssertEqual(seen, [.idle, .processing, .runningTool, .ended])

        dispose()
        store.ingest(payload: ["status": "processing"], envelopeNonce: "n4")
        XCTAssertEqual(seen.count, 4, "disposed observer must not fire")
    }
}
