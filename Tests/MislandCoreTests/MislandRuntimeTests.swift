import XCTest
import Darwin
@testable import MislandCore

/// Composition smoke test. Spins up a real runtime against a sandbox, drives
/// the full pipe (bridge → server → store → timeout coordinator) end-to-end,
/// and verifies that an idle (no UI click) PermissionRequest auto-denies.
final class MislandRuntimeTests: XCTestCase {
    private var sandboxRoot: URL!
    private var socketPath: String!
    private var settingsPath: String!
    private var runtime: MislandRuntime!

    override func setUp() {
        super.setUp()
        let shortID = String(UUID().uuidString.prefix(8))
        sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MislandRT-\(shortID)", isDirectory: true)
        SecurityPaths.overrideRoot = sandboxRoot
        socketPath = "/tmp/mm-rt-\(shortID).sock"
        settingsPath = sandboxRoot.appendingPathComponent("settings.json").path
        runtime = try! MislandRuntime(
            permissionTimeout: 0.1,    // fast tests
            socketPath: socketPath,
            settingsPath: settingsPath
        )
        try! runtime.start()
    }

    override func tearDown() {
        runtime?.stop()
        SecurityPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: sandboxRoot)
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testBridgeApprovalAutoDenies() throws {
        // Send a permission request and expect the auto-deny path to fire
        // *and* the bridge end of the connection to receive the deny.
        let env = try SocketEnvelope.sign(
            payload: [
                "status": "waiting_for_approval",
                "tool": "Bash",
                "tool_use_id": "u-1",
            ],
            key: runtime.key
        )
        var line = try env.encode()
        line.append(0x0a)

        let bridgeFD = try UnixSocket.connectClient(path: socketPath, sendTimeout: 2, recvTimeout: 5)
        defer { Darwin.close(bridgeFD) }
        try UnixSocket.writeAll(fd: bridgeFD, data: line)

        // Read reply (this is what the bridge would do).
        let reply = try UnixSocket.readLine(fd: bridgeFD)
        let verified = try SocketEnvelope.verify(rawJSON: reply, key: runtime.key, maxAgeSeconds: 60)
        XCTAssertEqual(verified.payload["decision"] as? String, "deny")
        XCTAssertEqual(verified.payload["reason"] as? String, "timeout")
    }

    func testBridgeProcessingNoDeny() throws {
        // A non-permission event must NOT cause a deny callback (defense in
        // depth: ensure the timeout coordinator doesn't react to other states).
        let env = try SocketEnvelope.sign(
            payload: ["status": "processing", "session_id": "s-1"],
            key: runtime.key
        )
        var line = try env.encode()
        line.append(0x0a)
        let fd = try UnixSocket.connectClient(path: socketPath)
        defer { Darwin.close(fd) }
        try UnixSocket.writeAll(fd: fd, data: line)

        // Brief wait — there's no reply expected.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(runtime.store.snapshot().status, .processing)
        XCTAssertNil(runtime.store.snapshot().pendingPermission)
    }

    func testInstallerWiredToCorrectPath() throws {
        try runtime.installer.install(bridgePath: "/test/path/misland-hook")
        XCTAssertTrue(runtime.installer.isInstalled(bridgePath: "/test/path/misland-hook"))
    }

    /// End-to-end multi-session: two simulated bridges (different session_ids)
    /// drive the same socket; SessionStore must track both as distinct entries
    /// and pick the right "active" one.
    func testMultipleClaudeSessionsTrackedSimultaneously() throws {
        func send(payload: [String: Any]) throws {
            let env = try SocketEnvelope.sign(payload: payload, key: runtime.key)
            var line = try env.encode()
            line.append(0x0a)
            let fd = try UnixSocket.connectClient(path: socketPath, sendTimeout: 2, recvTimeout: 1)
            defer { Darwin.close(fd) }
            try UnixSocket.writeAll(fd: fd, data: line)
        }

        try send(payload: [
            "status": "processing",
            "session_id": "claude-A",
            "cwd": "/Users/me/proj-A",
            "source": "claude_code",
        ])
        try send(payload: [
            "status": "running_tool",
            "session_id": "claude-B",
            "cwd": "/Users/me/proj-B",
            "tool": "Bash",
            "source": "claude_code",
        ])

        // Wait for ingest to settle (server is on a serial workQueue).
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, runtime.store.sessions.count < 2 {
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertEqual(runtime.store.sessions.count, 2,
                       "both Claude sessions should be tracked simultaneously")
        let ids = Set(runtime.store.sessions.compactMap(\.sessionId))
        XCTAssertEqual(ids, ["claude-A", "claude-B"])

        // Active should be claude-B (most recently updated).
        XCTAssertEqual(runtime.store.active?.sessionId, "claude-B")
        XCTAssertEqual(runtime.store.active?.tool, "Bash")
    }
}
