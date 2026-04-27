import Foundation
import CryptoKit

/// Wire envelope for every message exchanged between the hook bridge and the app.
///
/// Format (single-line JSON):
/// ```
/// {"v":1,"ts":"<ISO8601>","nonce":"<32 hex>","payload":<obj>,"mac":"<64 hex>"}
/// ```
/// `mac = HMAC-SHA256(key, "v=<v>;ts=<ts>;nonce=<n>;payload=" || canonical_json(payload))`.
/// Canonical JSON uses sorted keys with no slash escaping for stable bytes.
public struct SocketEnvelope: Equatable {
    public static let currentVersion = 1
    public static let nonceByteCount = 16
    public static let defaultMaxAgeSeconds: TimeInterval = 30

    public let version: Int
    public let timestamp: String  // ISO 8601 (UTC, seconds precision)
    public let nonce: String      // hex
    public let payload: [String: Any]
    public let mac: String        // hex

    public static func == (lhs: SocketEnvelope, rhs: SocketEnvelope) -> Bool {
        lhs.version == rhs.version &&
        lhs.timestamp == rhs.timestamp &&
        lhs.nonce == rhs.nonce &&
        lhs.mac == rhs.mac &&
        NSDictionary(dictionary: lhs.payload).isEqual(to: rhs.payload)
    }

    // MARK: - Sign

    public static func sign(
        payload: [String: Any],
        key: HMACKey,
        now: Date = Date(),
        nonceProvider: () -> String = SocketEnvelope.randomNonce
    ) throws -> SocketEnvelope {
        let ts = iso8601(now)
        let n = nonceProvider()
        let mac = try computeMAC(version: currentVersion, ts: ts, nonce: n, payload: payload, key: key)
        return SocketEnvelope(version: currentVersion, timestamp: ts, nonce: n, payload: payload, mac: mac)
    }

    // MARK: - Encode (sender)

    public func encode() throws -> Data {
        let obj: [String: Any] = [
            "v": version,
            "ts": timestamp,
            "nonce": nonce,
            "payload": payload,
            "mac": mac,
        ]
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Verify (receiver)

    public static func verify(
        rawJSON: Data,
        key: HMACKey,
        now: Date = Date(),
        maxAgeSeconds: TimeInterval = defaultMaxAgeSeconds
    ) throws -> SocketEnvelope {
        guard let obj = try JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] else {
            throw SocketEnvelopeError.malformed
        }
        guard let v = obj["v"] as? Int else { throw SocketEnvelopeError.malformed }
        guard v == currentVersion else { throw SocketEnvelopeError.unsupportedVersion(v) }
        guard let ts = obj["ts"] as? String,
              let nonce = obj["nonce"] as? String,
              let payload = obj["payload"] as? [String: Any],
              let mac = obj["mac"] as? String else {
            throw SocketEnvelopeError.malformed
        }
        let expectedMac = try computeMAC(version: v, ts: ts, nonce: nonce, payload: payload, key: key)
        guard constantTimeEquals(expectedMac, mac) else {
            throw SocketEnvelopeError.macMismatch
        }
        guard let date = parseISO8601(ts) else {
            throw SocketEnvelopeError.malformed
        }
        let age = abs(now.timeIntervalSince(date))
        if age > maxAgeSeconds {
            throw SocketEnvelopeError.stale(ageSeconds: age, max: maxAgeSeconds)
        }
        return SocketEnvelope(version: v, timestamp: ts, nonce: nonce, payload: payload, mac: mac)
    }

    // MARK: - Helpers

    public static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: nonceByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func computeMAC(
        version: Int,
        ts: String,
        nonce: String,
        payload: [String: Any],
        key: HMACKey
    ) throws -> String {
        let canonical = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let prefix = "v=\(version);ts=\(ts);nonce=\(nonce);payload=".data(using: .utf8)!
        var input = Data()
        input.append(prefix)
        input.append(canonical)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: key.raw)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

public enum SocketEnvelopeError: Error, Equatable {
    case malformed
    case unsupportedVersion(Int)
    case macMismatch
    case stale(ageSeconds: TimeInterval, max: TimeInterval)
}

// MARK: - Internal utilities

@inline(__always)
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    // Length leak is acceptable: MAC hex output is fixed-length, and the only way
    // these differ in length is if the message is malformed (already a fail).
    guard aBytes.count == bBytes.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<aBytes.count {
        diff |= aBytes[i] ^ bBytes[i]
    }
    return diff == 0
}

private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func iso8601(_ date: Date) -> String {
    iso8601Formatter.string(from: date)
}

func parseISO8601(_ s: String) -> Date? {
    iso8601Formatter.date(from: s)
}
