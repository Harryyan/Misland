import XCTest
import Darwin
@testable import MioMiniCore
import CryptoKit

/// End-to-end tests that drive a real AF_UNIX socket between an in-process
/// "bridge" (raw POSIX) and `HookSocketServer`. No subprocess involved — the
/// purpose is to lock down the wire protocol, replay defense, and reply path.
final class HookSocketServerTests: XCTestCase {
    private var sandboxRoot: URL!
    private var socketPath: String!
    private var key: HMACKey!
    private var server: HookSocketServer!
    private var store: SessionStore!

    override func setUp() {
        super.setUp()
        // sockaddr_un.sun_path is capped at 104 bytes on macOS, and
        // NSTemporaryDirectory() under SwiftPM resolves to a long
        // /var/folders/.../T/ path that blows the limit. Use /tmp directly
        // for the socket; the support-dir sandbox stays under tmpdir.
        let shortID = String(UUID().uuidString.prefix(8))
        sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MioMiniSrvTests-\(shortID)", isDirectory: true)
        SecurityPaths.overrideRoot = sandboxRoot
        socketPath = "/tmp/mm-\(shortID).sock"
        key = HMACKey(raw: SymmetricKey(size: .bits256))
        store = SessionStore()
        server = HookSocketServer(
            key: key,
            sessionStore: store,
            socketPath: socketPath
        )
        try! server.start()
    }

    override func tearDown() {
        server?.stop()
        SecurityPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: sandboxRoot)
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    // MARK: - Helpers

    private func sendSigned(payload: [String: Any], usingKey k: HMACKey? = nil) throws {
        let signKey = k ?? key!
        let env = try SocketEnvelope.sign(payload: payload, key: signKey)
        var line = try env.encode()
        line.append(0x0a)
        let fd = try UnixSocket.connectClient(path: socketPath, sendTimeout: 2, recvTimeout: 2)
        defer { Darwin.close(fd) }
        try UnixSocket.writeAll(fd: fd, data: line)
    }

    private func sendSignedExpectingReply(payload: [String: Any]) throws -> SocketEnvelope {
        let env = try SocketEnvelope.sign(payload: payload, key: key)
        var line = try env.encode()
        line.append(0x0a)
        let fd = try UnixSocket.connectClient(path: socketPath, sendTimeout: 2, recvTimeout: 5)
        defer { Darwin.close(fd) }
        try UnixSocket.writeAll(fd: fd, data: line)
        let reply = try UnixSocket.readLine(fd: fd)
        return try SocketEnvelope.verify(rawJSON: reply, key: key, maxAgeSeconds: 60)
    }

    private func waitForPredicate(
        timeout: TimeInterval = 1.0,
        _ predicate: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("predicate never became true within \(timeout)s")
    }

    // MARK: - Tests

    func testSocketFileExistsWithMode0600() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let attrs = try FileManager.default.attributesOfItem(atPath: socketPath)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600, "socket file must be mode 0600")
    }

    func testValidEventReachesStore() throws {
        try sendSigned(payload: [
            "status": "processing",
            "session_id": "s-1",
            "cwd": "/u/me",
        ])
        waitForPredicate { self.store.snapshot().status == .processing }
        XCTAssertEqual(store.snapshot().sessionId, "s-1")
    }

    func testWrongKeyDropped() throws {
        let attacker = HMACKey(raw: SymmetricKey(size: .bits256))
        try sendSigned(
            payload: ["status": "ended"],
            usingKey: attacker
        )
        // Brief wait to ensure server had a chance to process (and drop) it.
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(store.snapshot().status, .idle, "tampered envelope must not update store")
    }

    func testReplayDropped() throws {
        let env = try SocketEnvelope.sign(payload: ["status": "processing"], key: key)
        var line = try env.encode()
        line.append(0x0a)

        // Send the SAME signed bytes twice.
        for _ in 0..<2 {
            let fd = try UnixSocket.connectClient(path: socketPath)
            defer { Darwin.close(fd) }
            try UnixSocket.writeAll(fd: fd, data: line)
        }

        // First send → processing. Second send → dropped (no further state change).
        waitForPredicate { self.store.snapshot().status == .processing }
        let firstSeenAt = store.snapshot().lastUpdate

        // Send a DIFFERENT signed event with a different status to verify the
        // server is still alive and the replay drop didn't crash it.
        try sendSigned(payload: ["status": "ended"])
        waitForPredicate { self.store.snapshot().status == .ended }
        XCTAssertGreaterThan(store.snapshot().lastUpdate, firstSeenAt)
    }

    func testStaleEnvelopeDropped() throws {
        let oldDate = Date().addingTimeInterval(-120)
        let env = try SocketEnvelope.sign(
            payload: ["status": "processing"], key: key, now: oldDate
        )
        var line = try env.encode()
        line.append(0x0a)
        let fd = try UnixSocket.connectClient(path: socketPath)
        defer { Darwin.close(fd) }
        try UnixSocket.writeAll(fd: fd, data: line)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(store.snapshot().status, .idle)
    }

    func testPermissionRequestAllowReply() throws {
        // Bridge sends in one thread, awaiting reply.
        let bridgeReply = expectation(description: "bridge gets reply")
        var receivedDecision: String?
        DispatchQueue.global().async {
            do {
                let reply = try self.sendSignedExpectingReply(payload: [
                    "status": "waiting_for_approval",
                    "tool": "Bash",
                    "tool_use_id": "u-1",
                    "tool_input_json": "{\"command\":\"ls\"}",
                ])
                receivedDecision = reply.payload["decision"] as? String
                bridgeReply.fulfill()
            } catch {
                XCTFail("bridge send/recv failed: \(error)")
                bridgeReply.fulfill()
            }
        }

        // Server side: wait for the pending permission to be parked, then respond.
        waitForPredicate(timeout: 2.0) { self.store.snapshot().pendingPermission != nil }
        let pending = store.snapshot().pendingPermission!
        XCTAssertEqual(pending.tool, "Bash")
        XCTAssertEqual(server.pendingReplyCount, 1)

        try server.respond(toNonce: pending.envelopeNonce, decision: .allow)
        wait(for: [bridgeReply], timeout: 2)
        XCTAssertEqual(receivedDecision, "allow")
        XCTAssertEqual(server.pendingReplyCount, 0)
    }

    func testPermissionRequestDenyReply() throws {
        let bridgeReply = expectation(description: "bridge gets reply")
        var decision: String?
        var reason: String?
        DispatchQueue.global().async {
            do {
                let reply = try self.sendSignedExpectingReply(payload: [
                    "status": "waiting_for_approval",
                    "tool": "Bash",
                    "tool_use_id": "u-2",
                ])
                decision = reply.payload["decision"] as? String
                reason = reply.payload["reason"] as? String
                bridgeReply.fulfill()
            } catch {
                XCTFail("\(error)"); bridgeReply.fulfill()
            }
        }
        waitForPredicate(timeout: 2.0) { self.store.snapshot().pendingPermission != nil }
        try server.respond(
            toNonce: store.snapshot().pendingPermission!.envelopeNonce,
            decision: .deny,
            reason: "policy"
        )
        wait(for: [bridgeReply], timeout: 2)
        XCTAssertEqual(decision, "deny")
        XCTAssertEqual(reason, "policy")
    }

    func testStopClosesPendingConnections() throws {
        let bridgeDone = expectation(description: "bridge connection closes")
        DispatchQueue.global().async {
            do {
                let env = try SocketEnvelope.sign(
                    payload: ["status": "waiting_for_approval", "tool": "Bash", "tool_use_id": "u-9"],
                    key: self.key
                )
                var line = try env.encode()
                line.append(0x0a)
                let fd = try UnixSocket.connectClient(path: self.socketPath, sendTimeout: 2, recvTimeout: 5)
                defer { Darwin.close(fd) }
                try UnixSocket.writeAll(fd: fd, data: line)
                // Read should EOF when the server closes us during stop().
                _ = try? UnixSocket.readLine(fd: fd)
                bridgeDone.fulfill()
            } catch {
                bridgeDone.fulfill()
            }
        }
        waitForPredicate(timeout: 2.0) { self.server.pendingReplyCount == 1 }
        server.stop()
        wait(for: [bridgeDone], timeout: 2)
        XCTAssertEqual(server.pendingReplyCount, 0)
    }

    func testGarbageLineDoesNotCrash() throws {
        let fd = try UnixSocket.connectClient(path: socketPath)
        defer { Darwin.close(fd) }
        try UnixSocket.writeAll(fd: fd, data: "not json at all\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.05)
        // Server should still process valid events afterwards.
        try sendSigned(payload: ["status": "processing"])
        waitForPredicate { self.store.snapshot().status == .processing }
    }
}
