import XCTest
@testable import MislandCore

final class GeminiActivityWatcherTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        struct Call: Equatable {
            let status: String
            let source: String?
            let tool: String?
        }
        let lock = NSLock()
        var calls: [Call] = []
        func handler() -> GeminiActivityWatcher.Ingest {
            return { [weak self] payload, _ in
                self?.lock.lock()
                self?.calls.append(.init(
                    status: (payload["status"] as? String) ?? "?",
                    source: payload["source"] as? String,
                    tool: payload["tool"] as? String
                ))
                self?.lock.unlock()
            }
        }
        var snapshot: [Call] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MislandGemini-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    private func waitFor(_ timeout: TimeInterval = 1, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // MARK: - Existence / startup

    func testNoExistingPathsIsNoOp() {
        let recorder = Recorder()
        let nonexistent = "/tmp/nonexistent-mio-\(UUID().uuidString)"
        let w = GeminiActivityWatcher(
            watchPaths: [nonexistent],
            ingest: recorder.handler()
        )
        w.start()
        defer { w.stop() }
        XCTAssertFalse(w.isStarted, "no real paths → no FSEventStream")
        XCTAssertEqual(recorder.snapshot, [])
    }

    func testExistingPathStartsWatcher() {
        let recorder = Recorder()
        let w = GeminiActivityWatcher(
            watchPaths: [sandbox.path],
            idleAfter: 60,
            fsEventLatency: 0.05,
            ingest: recorder.handler()
        )
        w.start()
        defer { w.stop() }
        XCTAssertTrue(w.isStarted)
    }

    // MARK: - Activity → status transitions

    func testInjectActivityProducesProcessing() {
        let recorder = Recorder()
        let w = GeminiActivityWatcher(
            watchPaths: [sandbox.path],
            idleAfter: 60,
            fsEventLatency: 0.05,
            ingest: recorder.handler()
        )
        w.start()
        defer { w.stop() }

        w._injectActivityForTest()
        waitFor { recorder.snapshot.count == 1 }
        XCTAssertEqual(recorder.snapshot, [
            .init(status: "processing", source: "gemini_cli", tool: "gemini")
        ])
    }

    func testIdleAfterFiresWaitingForInput() {
        let recorder = Recorder()
        let w = GeminiActivityWatcher(
            watchPaths: [sandbox.path],
            idleAfter: 0.1,
            fsEventLatency: 0.05,
            ingest: recorder.handler()
        )
        w.start()
        defer { w.stop() }

        w._injectActivityForTest()
        waitFor { recorder.snapshot.count == 2 }
        XCTAssertEqual(recorder.snapshot.map(\.status), ["processing", "waiting_for_input"])
    }

    func testRapidEventsCoalesceToOneProcessing() {
        let recorder = Recorder()
        let w = GeminiActivityWatcher(
            watchPaths: [sandbox.path],
            idleAfter: 60,
            fsEventLatency: 0.05,
            ingest: recorder.handler()
        )
        w.start()
        defer { w.stop() }

        for _ in 0..<10 { w._injectActivityForTest() }
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(recorder.snapshot.count, 1, "burst must coalesce to one transition")
    }

    func testFSEventTriggersOnRealFileWrite() throws {
        let recorder = Recorder()
        let w = GeminiActivityWatcher(
            watchPaths: [sandbox.path],
            idleAfter: 60,
            fsEventLatency: 0.05,
            ingest: recorder.handler()
        )
        w.start()
        defer { w.stop() }

        // Real file write — exercises the actual FSEventStream path.
        let target = sandbox.appendingPathComponent("session.jsonl")
        try Data("hello\n".utf8).write(to: target)

        waitFor(2.0) { recorder.snapshot.count >= 1 }
        XCTAssertGreaterThanOrEqual(recorder.snapshot.count, 1, "real file write must trigger FSEvents")
        XCTAssertEqual(recorder.snapshot.first?.status, "processing")
    }

    func testEnvVarOverride() {
        setenv("MISLAND_GEMINI_DIR", "/some/explicit/path", 1)
        defer { unsetenv("MISLAND_GEMINI_DIR") }
        XCTAssertEqual(GeminiActivityWatcher.defaultPaths(), ["/some/explicit/path"])
    }
}
