import XCTest
import Darwin
@testable import MioMiniCore

/// Composition smoke test. Spins up a real runtime against a sandbox, drives
/// the full pipe (bridge → server → store → timeout coordinator) end-to-end,
/// and verifies that an idle (no UI click) PermissionRequest auto-denies.
final class MioMiniRuntimeTests: XCTestCase {
    private var sandboxRoot: URL!
    private var socketPath: String!
    private var settingsPath: String!
    private var runtime: MioMiniRuntime!

    override func setUp() {
        super.setUp()
        let shortID = String(UUID().uuidString.prefix(8))
        sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MioMiniRT-\(shortID)", isDirectory: true)
        SecurityPaths.overrideRoot = sandboxRoot
        socketPath = "/tmp/mm-rt-\(shortID).sock"
        settingsPath = sandboxRoot.appendingPathComponent("settings.json").path
        runtime = try! MioMiniRuntime(
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
        try runtime.installer.install(bridgePath: "/test/path/miomini-hook")
        XCTAssertTrue(runtime.installer.isInstalled(bridgePath: "/test/path/miomini-hook"))
    }
}
