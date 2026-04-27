import XCTest
@testable import MioMiniCore

final class SessionStoreSourcePriorityTests: XCTestCase {
    func testGeminiIngestIgnoredWhilePermissionPending() {
        let store = SessionStore()
        store.ingest(
            payload: [
                "status": "waiting_for_approval",
                "source": "claude_code",
                "tool": "Bash",
                "tool_use_id": "u-1",
            ],
            envelopeNonce: "claude-1"
        )
        XCTAssertNotNil(store.snapshot().pendingPermission)
        XCTAssertEqual(store.snapshot().source, "claude_code")

        // Gemini's read-only ingest must NOT clobber the pending Claude approval.
        store.ingest(
            payload: ["status": "processing", "source": "gemini_cli", "tool": "gemini"],
            envelopeNonce: "gemini-1"
        )

        let s = store.snapshot()
        XCTAssertEqual(s.status, .waitingForApproval, "Gemini must not change status while Claude is awaiting approval")
        XCTAssertNotNil(s.pendingPermission)
        XCTAssertEqual(s.source, "claude_code")
    }

    func testGeminiIngestOKWhenNoPending() {
        let store = SessionStore()
        store.ingest(
            payload: ["status": "processing", "source": "gemini_cli", "tool": "gemini"],
            envelopeNonce: "g-1"
        )
        XCTAssertEqual(store.snapshot().status, .processing)
        XCTAssertEqual(store.snapshot().source, "gemini_cli")
    }

    func testClaudeAlwaysWinsRegardlessOfRecency() {
        let store = SessionStore()
        store.ingest(
            payload: ["status": "processing", "source": "gemini_cli"],
            envelopeNonce: "g-1"
        )
        store.ingest(
            payload: [
                "status": "waiting_for_approval",
                "source": "claude_code",
                "tool": "Bash",
                "tool_use_id": "u-1",
            ],
            envelopeNonce: "c-1"
        )
        // Now Gemini sends another update — must not clobber the new pending.
        store.ingest(
            payload: ["status": "waiting_for_input", "source": "gemini_cli"],
            envelopeNonce: "g-2"
        )
        XCTAssertNotNil(store.snapshot().pendingPermission)
        XCTAssertEqual(store.snapshot().status, .waitingForApproval)
    }

    func testDefaultSourceIsClaude() {
        // Hooks bridge omits source if it forgot to add it — assume claude_code
        // (so we don't accidentally allow a stale ingest to lose to "gemini_cli").
        let store = SessionStore()
        store.ingest(
            payload: ["status": "waiting_for_approval", "tool": "Bash", "tool_use_id": "u-1"],
            envelopeNonce: "n1"
        )
        XCTAssertEqual(store.snapshot().source, "claude_code")
    }
}
