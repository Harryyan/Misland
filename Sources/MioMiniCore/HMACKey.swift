import Foundation
import CryptoKit

/// 256-bit symmetric key used for HMAC-SHA256 signing of socket envelopes.
///
/// Persisted at `SecurityPaths.secretKeyPath` with mode 0600. On load the file mode is
/// re-checked: if any group/other bits are set the load fails, forcing the user to
/// regenerate a key rather than continue with a leaked one (PRD §6 SEC-2).
public struct HMACKey {
    public static let keyByteCount = 32  // 256 bits

    public let raw: SymmetricKey

    public init(raw: SymmetricKey) {
        self.raw = raw
    }

    /// Load the key if it exists, otherwise create a fresh random one.
    public static func loadOrCreate(at path: String? = nil) throws -> HMACKey {
        try SecurityPaths.ensureSupportDirectory()
        let p = path ?? SecurityPaths.secretKeyPath
        let fm = FileManager.default
        if fm.fileExists(atPath: p) {
            return try load(at: p)
        }
        return try create(at: p)
    }

    /// Force-create a new key, overwriting any existing one. Used by `Reset Pairing`.
    public static func create(at path: String? = nil) throws -> HMACKey {
        try SecurityPaths.ensureSupportDirectory()
        let p = path ?? SecurityPaths.secretKeyPath
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        precondition(data.count == keyByteCount)

        // Write atomically, then enforce mode 0600 on the final path.
        try data.write(to: URL(fileURLWithPath: p), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
        return HMACKey(raw: key)
    }

    public static func load(at path: String? = nil) throws -> HMACKey {
        let p = path ?? SecurityPaths.secretKeyPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: p) else {
            throw HMACKeyError.keyFileMissing(path: p)
        }
        let attrs = try fm.attributesOfItem(atPath: p)
        guard let modeNum = attrs[.posixPermissions] as? NSNumber else {
            throw HMACKeyError.cannotReadMode(path: p)
        }
        let mode = modeNum.intValue & 0o777
        // Reject if any group or other bits are set.
        if mode & 0o077 != 0 {
            throw HMACKeyError.keyFileTooPermissive(path: p, actualMode: mode)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: p))
        guard data.count == keyByteCount else {
            throw HMACKeyError.invalidKeyLength(actual: data.count, expected: keyByteCount)
        }
        return HMACKey(raw: SymmetricKey(data: data))
    }
}

public enum HMACKeyError: Error, Equatable {
    case keyFileMissing(path: String)
    case cannotReadMode(path: String)
    case keyFileTooPermissive(path: String, actualMode: Int)
    case invalidKeyLength(actual: Int, expected: Int)
}
