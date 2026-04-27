import XCTest
@testable import MioMiniCore
import CryptoKit

final class SocketEnvelopeTests: XCTestCase {
    private var key: HMACKey!
    private var sandboxRoot: URL!

    override func setUp() {
        super.setUp()
        sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MioMiniTests-\(UUID().uuidString)", isDirectory: true)
        SecurityPaths.overrideRoot = sandboxRoot
        key = HMACKey(raw: SymmetricKey(size: .bits256))
    }

    override func tearDown() {
        SecurityPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: sandboxRoot)
        super.tearDown()
    }

    // MARK: - Roundtrip

    func testSignEncodeVerifyRoundtrip() throws {
        let payload: [String: Any] = [
            "status": "processing",
            "session_id": "abc-123",
            "pid": 4242,
        ]
        let env = try SocketEnvelope.sign(payload: payload, key: key)
        let wire = try env.encode()
        let verified = try SocketEnvelope.verify(rawJSON: wire, key: key)
        XCTAssertEqual(verified.timestamp, env.timestamp)
        XCTAssertEqual(verified.nonce, env.nonce)
        XCTAssertEqual(verified.mac, env.mac)
        XCTAssertEqual(verified.payload["status"] as? String, "processing")
        XCTAssertEqual(verified.payload["session_id"] as? String, "abc-123")
        XCTAssertEqual(verified.payload["pid"] as? Int, 4242)
    }

    // MARK: - Tampering detection

    func testTamperedPayloadIsRejected() throws {
        let env = try SocketEnvelope.sign(payload: ["status": "processing"], key: key)
        let wire = try env.encode()
        // Flip "processing" → "approved" inside the wire bytes.
        var s = String(data: wire, encoding: .utf8)!
        s = s.replacingOccurrences(of: "processing", with: "Approved!!")
        let tampered = s.data(using: .utf8)!
        XCTAssertThrowsError(try SocketEnvelope.verify(rawJSON: tampered, key: key)) { err in
            XCTAssertEqual(err as? SocketEnvelopeError, .macMismatch)
        }
    }

    func testWrongKeyRejected() throws {
        let env = try SocketEnvelope.sign(payload: ["status": "processing"], key: key)
        let wire = try env.encode()
        let otherKey = HMACKey(raw: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try SocketEnvelope.verify(rawJSON: wire, key: otherKey)) { err in
            XCTAssertEqual(err as? SocketEnvelopeError, .macMismatch)
        }
    }

    func testTamperedTimestampRejected() throws {
        let env = try SocketEnvelope.sign(payload: ["status": "processing"], key: key)
        // Substitute a different (still valid format) timestamp without recomputing MAC.
        let bogus = SocketEnvelope(
            version: env.version,
            timestamp: iso8601(Date().addingTimeInterval(-5)),
            nonce: env.nonce,
            payload: env.payload,
            mac: env.mac
        )
        let wire = try bogus.encode()
        XCTAssertThrowsError(try SocketEnvelope.verify(rawJSON: wire, key: key)) { err in
            XCTAssertEqual(err as? SocketEnvelopeError, .macMismatch)
        }
    }

    func testTamperedNonceRejected() throws {
        let env = try SocketEnvelope.sign(payload: ["status": "processing"], key: key)
        let bogus = SocketEnvelope(
            version: env.version,
            timestamp: env.timestamp,
            nonce: String(repeating: "0", count: 32),
            payload: env.payload,
            mac: env.mac
        )
        let wire = try bogus.encode()
        XCTAssertThrowsError(try SocketEnvelope.verify(rawJSON: wire, key: key)) { err in
            XCTAssertEqual(err as? SocketEnvelopeError, .macMismatch)
        }
    }

    // MARK: - Freshness

    func testStaleEnvelopeRejected() throws {
        let oldDate = Date().addingTimeInterval(-120)
        let env = try SocketEnvelope.sign(payload: ["status": "processing"], key: key, now: oldDate)
        let wire = try env.encode()
        XCTAssertThrowsError(try SocketEnvelope.verify(rawJSON: wire, key: key, maxAgeSeconds: 30)) { err in
            guard case .stale = err as? SocketEnvelopeError else {
                return XCTFail("expected stale, got \(err)")
            }
        }
    }

    func testFutureEnvelopeAlsoRejected() throws {
        let futureDate = Date().addingTimeInterval(120)
        let env = try SocketEnvelope.sign(payload: ["status": "processing"], key: key, now: futureDate)
        let wire = try env.encode()
        XCTAssertThrowsError(try SocketEnvelope.verify(rawJSON: wire, key: key, maxAgeSeconds: 30)) { err in
            guard case .stale = err as? SocketEnvelopeError else {
                return XCTFail("expected stale, got \(err)")
            }
        }
    }

    // MARK: - Format

    func testMalformedJsonRejected() {
        let garbage = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try SocketEnvelope.verify(rawJSON: garbage, key: key))
    }

    func testWrongVersionRejected() throws {
        let bogus: [String: Any] = [
            "v": 99,
            "ts": iso8601(Date()),
            "nonce": "00000000000000000000000000000000",
            "payload": ["status": "processing"],
            "mac": String(repeating: "0", count: 64),
        ]
        let wire = try JSONSerialization.data(withJSONObject: bogus)
        XCTAssertThrowsError(try SocketEnvelope.verify(rawJSON: wire, key: key)) { err in
            guard case .unsupportedVersion(99) = err as? SocketEnvelopeError else {
                return XCTFail("expected unsupportedVersion, got \(err)")
            }
        }
    }

    // MARK: - Determinism

    func testSameInputsProduceSameMAC() throws {
        let payload: [String: Any] = ["a": 1, "b": "two", "c": [1, 2, 3]]
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nonce = "deadbeefcafebabedeadbeefcafebabe"
        let e1 = try SocketEnvelope.sign(payload: payload, key: key, now: now, nonceProvider: { nonce })
        let e2 = try SocketEnvelope.sign(payload: payload, key: key, now: now, nonceProvider: { nonce })
        XCTAssertEqual(e1.mac, e2.mac, "MAC must be deterministic for same inputs")
    }

    func testKeyOrderIndependence() throws {
        // Canonical JSON sorts keys, so payload semantic-equal dicts must produce the same MAC.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nonce = "00112233445566778899aabbccddeeff"
        let p1: [String: Any] = ["alpha": 1, "beta": 2, "gamma": 3]
        let p2: [String: Any] = ["gamma": 3, "alpha": 1, "beta": 2]
        let e1 = try SocketEnvelope.sign(payload: p1, key: key, now: now, nonceProvider: { nonce })
        let e2 = try SocketEnvelope.sign(payload: p2, key: key, now: now, nonceProvider: { nonce })
        XCTAssertEqual(e1.mac, e2.mac)
    }

    // MARK: - Constant-time compare

    func testConstantTimeEqualsBasic() {
        XCTAssertTrue(constantTimeEquals("abc", "abc"))
        XCTAssertFalse(constantTimeEquals("abc", "abd"))
        XCTAssertFalse(constantTimeEquals("abc", "ab"))
        XCTAssertFalse(constantTimeEquals("", "x"))
        XCTAssertTrue(constantTimeEquals("", ""))
    }
}
