import XCTest
@testable import MioMiniCore

final class HookInstallerServiceTests: XCTestCase {
    private var sandboxRoot: URL!
    private var settingsPath: String!
    private let bridgePath = "/Applications/MioMini.app/Contents/MacOS/miomini-hook"

    override func setUp() {
        super.setUp()
        sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MioMiniInstSvc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        settingsPath = sandboxRoot.appendingPathComponent(".claude/settings.json").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sandboxRoot)
        super.tearDown()
    }

    // MARK: - Fresh install

    func testInstallCreatesParentDirectory() throws {
        let svc = HookInstallerService(settingsPath: settingsPath)
        try svc.install(bridgePath: bridgePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsPath))
        XCTAssertTrue(svc.isInstalled(bridgePath: bridgePath))
    }

    func testInstallEmptyFile() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: settingsPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: URL(fileURLWithPath: settingsPath))
        let svc = HookInstallerService(settingsPath: settingsPath)
        try svc.install(bridgePath: bridgePath)
        XCTAssertTrue(svc.isInstalled(bridgePath: bridgePath))
    }

    // MARK: - Round-trip

    func testInstallUninstallRoundTripPreservesUserSettings() throws {
        // Pre-existing user settings.json with an unrelated user hook + custom keys.
        let original: [String: Any] = [
            "model": "sonnet-4.6",
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [["type": "command", "command": "/usr/local/bin/audit"]],
                    ]
                ]
            ],
        ]
        try writeJSON(original, to: settingsPath)

        let svc = HookInstallerService(settingsPath: settingsPath)
        try svc.install(bridgePath: bridgePath)
        XCTAssertTrue(svc.isInstalled(bridgePath: bridgePath))

        // After uninstall the file should be byte-equivalent (after canonicalization)
        // to the original.
        try svc.uninstall()
        XCTAssertFalse(svc.isInstalled(bridgePath: bridgePath))

        let after = try readJSON(at: settingsPath)
        // Compare via canonicalized JSON.
        let canonOriginal = try canonical(original)
        let canonAfter = try canonical(after)
        XCTAssertEqual(canonOriginal, canonAfter,
                       "uninstall must restore the file to its pre-install state")
    }

    // MARK: - Failure modes

    func testMalformedSettingsThrows() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: settingsPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{ this is not valid json }".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        let svc = HookInstallerService(settingsPath: settingsPath)
        XCTAssertThrowsError(try svc.install(bridgePath: bridgePath)) { err in
            guard case .malformedSettings = err as? HookInstallerServiceError else {
                return XCTFail("expected malformedSettings, got \(err)")
            }
        }
    }

    func testTopLevelArrayThrows() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: settingsPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "[1, 2, 3]".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        let svc = HookInstallerService(settingsPath: settingsPath)
        XCTAssertThrowsError(try svc.install(bridgePath: bridgePath)) { err in
            guard case .malformedSettings = err as? HookInstallerServiceError else {
                return XCTFail("expected malformedSettings, got \(err)")
            }
        }
    }

    func testInstallIsIdempotent() throws {
        let svc = HookInstallerService(settingsPath: settingsPath)
        try svc.install(bridgePath: bridgePath)
        try svc.install(bridgePath: bridgePath)
        let after = try readJSON(at: settingsPath)
        let hooks = after["hooks"] as? [String: Any]
        for event in HookInstaller.managedEvents {
            let entries = hooks?[event] as? [[String: Any]]
            XCTAssertEqual(entries?.count, 1, "double install must not duplicate \(event)")
        }
    }

    func testInstallUpdatesBridgePath() throws {
        let svc = HookInstallerService(settingsPath: settingsPath)
        let oldPath = "/old/path"
        let newPath = "/new/path"
        try svc.install(bridgePath: oldPath)
        XCTAssertTrue(svc.isInstalled(bridgePath: oldPath))
        try svc.install(bridgePath: newPath)
        XCTAssertTrue(svc.isInstalled(bridgePath: newPath))
        XCTAssertFalse(svc.isInstalled(bridgePath: oldPath))
    }

    // MARK: - Helpers

    private func writeJSON(_ obj: [String: Any], to path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func readJSON(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func canonical(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
