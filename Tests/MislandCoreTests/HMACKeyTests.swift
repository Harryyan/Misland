import XCTest
@testable import MislandCore

final class HMACKeyTests: XCTestCase {
    private var sandboxRoot: URL!

    override func setUp() {
        super.setUp()
        sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MislandTests-\(UUID().uuidString)", isDirectory: true)
        SecurityPaths.overrideRoot = sandboxRoot
    }

    override func tearDown() {
        SecurityPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: sandboxRoot)
        super.tearDown()
    }

    func testCreateThenLoadRoundTrip() throws {
        let created = try HMACKey.create()
        let loaded = try HMACKey.load()
        let createdRaw = created.raw.withUnsafeBytes { Data($0) }
        let loadedRaw = loaded.raw.withUnsafeBytes { Data($0) }
        XCTAssertEqual(createdRaw, loadedRaw)
        XCTAssertEqual(createdRaw.count, HMACKey.keyByteCount)
    }

    func testLoadOrCreateIdempotent() throws {
        let a = try HMACKey.loadOrCreate()
        let b = try HMACKey.loadOrCreate()
        XCTAssertEqual(
            a.raw.withUnsafeBytes { Data($0) },
            b.raw.withUnsafeBytes { Data($0) }
        )
    }

    func testKeyFileWrittenWithMode0600() throws {
        _ = try HMACKey.create()
        let attrs = try FileManager.default.attributesOfItem(atPath: SecurityPaths.secretKeyPath)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600, "key file must be mode 0600")
    }

    func testSupportDirectoryHasMode0700() throws {
        try SecurityPaths.ensureSupportDirectory()
        let attrs = try FileManager.default.attributesOfItem(atPath: SecurityPaths.supportDirectory.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o700, "support dir must be mode 0700")
    }

    func testLoadRejectsTooPermissiveKey() throws {
        _ = try HMACKey.create()
        // Loosen mode to 0644 — load must refuse.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: SecurityPaths.secretKeyPath
        )
        XCTAssertThrowsError(try HMACKey.load()) { err in
            guard case .keyFileTooPermissive(_, let mode) = err as? HMACKeyError else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(mode, 0o644)
        }
    }

    func testLoadRejectsAnyGroupOrOtherBit() throws {
        _ = try HMACKey.create()
        // Even a single 'group read' bit must trigger refusal.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: SecurityPaths.secretKeyPath
        )
        XCTAssertThrowsError(try HMACKey.load()) { err in
            guard case .keyFileTooPermissive = err as? HMACKeyError else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func testLoadMissingFileError() {
        XCTAssertThrowsError(try HMACKey.load()) { err in
            guard case .keyFileMissing = err as? HMACKeyError else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func testCreateOverwritesExisting() throws {
        let a = try HMACKey.create()
        let b = try HMACKey.create()
        XCTAssertNotEqual(
            a.raw.withUnsafeBytes { Data($0) },
            b.raw.withUnsafeBytes { Data($0) },
            "create() must always produce a fresh key"
        )
    }

    func testInvalidLengthRejected() throws {
        try SecurityPaths.ensureSupportDirectory()
        let path = SecurityPaths.secretKeyPath
        try Data(repeating: 0, count: 16).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
        XCTAssertThrowsError(try HMACKey.load()) { err in
            guard case .invalidKeyLength(let actual, let expected) = err as? HMACKeyError else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(actual, 16)
            XCTAssertEqual(expected, 32)
        }
    }
}
