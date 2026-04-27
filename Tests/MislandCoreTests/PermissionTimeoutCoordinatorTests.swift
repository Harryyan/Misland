import XCTest
@testable import MislandCore

final class PermissionTimeoutCoordinatorTests: XCTestCase {
    /// Uses the shortest possible timeout (50 ms) so the suite stays fast.
    private let testTimeout: TimeInterval = 0.05

    private final class RecordingResponder: @unchecked Sendable {
        struct Call: Equatable {
            let nonce: String
            let decision: PermissionDecision
            let reason: String?
        }
        let lock = NSLock()
        var calls: [Call] = []
        func handler() -> PermissionTimeoutCoordinator.Responder {
            return { [weak self] nonce, decision, reason in
                self?.lock.lock()
                self?.calls.append(.init(nonce: nonce, decision: decision, reason: reason))
                self?.lock.unlock()
            }
        }
        var snapshot: [Call] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    private func ingestApproval(_ store: SessionStore, nonce: String, sessionId: String = "default") {
        store.ingest(
            payload: [
                "status": "waiting_for_approval",
                "session_id": sessionId,
                "tool": "Bash",
                "tool_use_id": "u-\(nonce)",
            ],
            envelopeNonce: nonce
        )
    }

    private func waitFor(timeout: TimeInterval = 1, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func testTimerFiresDenyAfterTimeout() {
        let store = SessionStore()
        let recorder = RecordingResponder()
        let coord = PermissionTimeoutCoordinator(
            timeout: testTimeout, store: store, respond: recorder.handler()
        )
        coord.start()
        defer { coord.stop() }

        ingestApproval(store, nonce: "n1")
        waitFor { recorder.snapshot.count == 1 }
        XCTAssertEqual(recorder.snapshot, [
            .init(nonce: "n1", decision: .deny, reason: "timeout")
        ])
    }

    func testCancelledByUserDecisionBeforeTimeout() {
        let store = SessionStore()
        let recorder = RecordingResponder()
        let coord = PermissionTimeoutCoordinator(
            timeout: 1.0, store: store, respond: recorder.handler()
        )
        coord.start()
        defer { coord.stop() }

        ingestApproval(store, nonce: "n1")
        XCTAssertTrue(coord.isArmed)

        // Simulate user clicking Allow → SessionStore receives a non-approval status.
        store.ingest(payload: ["status": "processing"], envelopeNonce: "n2")
        waitFor(timeout: 0.5) { coord.isArmed == false }
        XCTAssertFalse(coord.isArmed, "timer must be cancelled when pending clears")

        // Wait long enough that the original timer would have fired.
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(recorder.snapshot, [], "no responder call should happen")
    }

    func testNewPendingResetsTimer() {
        let store = SessionStore()
        let recorder = RecordingResponder()
        let coord = PermissionTimeoutCoordinator(
            timeout: 0.3, store: store, respond: recorder.handler()
        )
        coord.start()
        defer { coord.stop() }

        ingestApproval(store, nonce: "n1")
        Thread.sleep(forTimeInterval: 0.1)
        ingestApproval(store, nonce: "n2")
        waitFor { recorder.snapshot.count == 1 }
        XCTAssertEqual(recorder.snapshot.first?.nonce, "n2",
                       "second pending replaces the first")
    }

    func testNoChangeKeepsTimerRunning() {
        // Pathological: two ingests with identical nonce (e.g. ingest fires for
        // some other field update). The timer must NOT reset, otherwise SEC-5
        // could be defeated by a noisy stream.
        let store = SessionStore()
        let recorder = RecordingResponder()
        let coord = PermissionTimeoutCoordinator(
            timeout: 0.15, store: store, respond: recorder.handler()
        )
        coord.start()
        defer { coord.stop() }

        ingestApproval(store, nonce: "n1")
        // Re-ingest same approval payload several times.
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.04)
            ingestApproval(store, nonce: "n1")
        }
        waitFor { recorder.snapshot.count == 1 }
        XCTAssertEqual(recorder.snapshot.first?.nonce, "n1")
    }

    func testStopCancelsArmedTimer() {
        let store = SessionStore()
        let recorder = RecordingResponder()
        let coord = PermissionTimeoutCoordinator(
            timeout: 0.5, store: store, respond: recorder.handler()
        )
        coord.start()
        ingestApproval(store, nonce: "n1")
        XCTAssertTrue(coord.isArmed)

        coord.stop()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(recorder.snapshot, [], "stop() must prevent timer fire")
    }

    func testRestartAfterStop() {
        let store = SessionStore()
        let recorder = RecordingResponder()
        let coord = PermissionTimeoutCoordinator(
            timeout: testTimeout, store: store, respond: recorder.handler()
        )
        coord.start()
        coord.stop()
        coord.start()
        defer { coord.stop() }

        ingestApproval(store, nonce: "after-restart")
        waitFor { recorder.snapshot.count == 1 }
        XCTAssertEqual(recorder.snapshot.first?.nonce, "after-restart")
    }

    // MARK: - Multi-session

    func testMultipleSessionsEachGetIndependentTimer() {
        let store = SessionStore()
        let recorder = RecordingResponder()
        let coord = PermissionTimeoutCoordinator(
            timeout: testTimeout, store: store, respond: recorder.handler()
        )
        coord.start()
        defer { coord.stop() }

        ingestApproval(store, nonce: "n1", sessionId: "claude-A")
        ingestApproval(store, nonce: "n2", sessionId: "claude-B")
        XCTAssertEqual(coord.armedCount, 2)
        XCTAssertEqual(coord.armedNonces, ["n1", "n2"])

        // Both timers should fire deny independently.
        waitFor { recorder.snapshot.count == 2 }
        let nonces = Set(recorder.snapshot.map(\.nonce))
        XCTAssertEqual(nonces, ["n1", "n2"])
        XCTAssertEqual(recorder.snapshot.allSatisfy { $0.decision == .deny }, true)
    }

    func testResolvingOneSessionDoesNotCancelOthers() {
        let store = SessionStore()
        let recorder = RecordingResponder()
        let coord = PermissionTimeoutCoordinator(
            timeout: 0.5, store: store, respond: recorder.handler()
        )
        coord.start()
        defer { coord.stop() }

        ingestApproval(store, nonce: "n1", sessionId: "claude-A")
        ingestApproval(store, nonce: "n2", sessionId: "claude-B")
        XCTAssertEqual(coord.armedCount, 2)

        // User resolves session A by sending a non-approval status.
        store.ingest(
            payload: ["status": "processing", "session_id": "claude-A"],
            envelopeNonce: "resolve-A"
        )
        waitFor(timeout: 0.3) { coord.armedNonces == ["n2"] }
        XCTAssertEqual(coord.armedNonces, ["n2"], "only A's timer cancels; B keeps counting")

        // B's timer still fires.
        waitFor(timeout: 1.0) { recorder.snapshot.count == 1 }
        XCTAssertEqual(recorder.snapshot.first?.nonce, "n2")
    }

    func testThreeSessionsAllFireWhenLeftAlone() {
        let store = SessionStore()
        let recorder = RecordingResponder()
        let coord = PermissionTimeoutCoordinator(
            timeout: testTimeout, store: store, respond: recorder.handler()
        )
        coord.start()
        defer { coord.stop() }

        ingestApproval(store, nonce: "a", sessionId: "s1")
        ingestApproval(store, nonce: "b", sessionId: "s2")
        ingestApproval(store, nonce: "c", sessionId: "s3")
        XCTAssertEqual(coord.armedCount, 3)

        waitFor { recorder.snapshot.count == 3 }
        XCTAssertEqual(Set(recorder.snapshot.map(\.nonce)), ["a", "b", "c"])
    }

    func testStopCancelsAllArmedTimers() {
        let store = SessionStore()
        let recorder = RecordingResponder()
        let coord = PermissionTimeoutCoordinator(
            timeout: 0.5, store: store, respond: recorder.handler()
        )
        coord.start()

        ingestApproval(store, nonce: "n1", sessionId: "s1")
        ingestApproval(store, nonce: "n2", sessionId: "s2")
        XCTAssertEqual(coord.armedCount, 2)

        coord.stop()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(recorder.snapshot, [], "stop() must cancel every timer")
    }
}
