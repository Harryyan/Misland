import XCTest
@testable import MislandCore

final class HookInstallerTests: XCTestCase {
    let bridgePath = "/Applications/Misland.app/Contents/MacOS/misland-hook"

    func testInstallIntoEmptySettings() {
        let installed = HookInstaller.install(into: [:], bridgePath: bridgePath)
        XCTAssertTrue(HookInstaller.isInstalled(in: installed, bridgePath: bridgePath))
        let hooks = installed["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks)
        for event in HookInstaller.managedEvents {
            let entries = hooks?[event] as? [[String: Any]]
            XCTAssertEqual(entries?.count, 1, "expected exactly 1 entry for \(event)")
        }
    }

    func testInstallPreservesUserHooks() throws {
        let userHook: [String: Any] = [
            "matcher": "Bash",
            "hooks": [["type": "command", "command": "/usr/local/bin/my-audit"]],
        ]
        let original: [String: Any] = [
            "hooks": [
                "PreToolUse": [userHook],
                "Stop": [userHook],
            ],
            "model": "sonnet-4.6",  // unrelated user setting
        ]
        let installed = HookInstaller.install(into: original, bridgePath: bridgePath)
        let hooks = installed["hooks"] as? [String: Any]

        // User entries must still be present.
        let pre = hooks?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(pre?.count, 2, "user entry + ours")
        XCTAssertEqual(pre?.first?["matcher"] as? String, "Bash")

        // Unrelated settings preserved.
        XCTAssertEqual(installed["model"] as? String, "sonnet-4.6")
    }

    func testReinstallIsIdempotent() {
        let once = HookInstaller.install(into: [:], bridgePath: bridgePath)
        let twice = HookInstaller.install(into: once, bridgePath: bridgePath)
        let thrice = HookInstaller.install(into: twice, bridgePath: bridgePath)

        // Each event still has exactly one managed entry.
        let hooks = thrice["hooks"] as? [String: Any]
        for event in HookInstaller.managedEvents {
            let entries = hooks?[event] as? [[String: Any]]
            XCTAssertEqual(entries?.count, 1, "event \(event) should not duplicate")
        }
    }

    func testReinstallUpdatesPath() {
        let oldPath = "/old/path/misland-hook"
        let newPath = "/Applications/Misland.app/Contents/MacOS/misland-hook"
        let s1 = HookInstaller.install(into: [:], bridgePath: oldPath)
        XCTAssertTrue(HookInstaller.isInstalled(in: s1, bridgePath: oldPath))

        let s2 = HookInstaller.install(into: s1, bridgePath: newPath)
        XCTAssertTrue(HookInstaller.isInstalled(in: s2, bridgePath: newPath))
        XCTAssertFalse(HookInstaller.isInstalled(in: s2, bridgePath: oldPath))
    }

    func testUninstallRemovesOnlyOurs() {
        let userHook: [String: Any] = [
            "matcher": "Bash",
            "hooks": [["type": "command", "command": "/usr/local/bin/my-audit"]],
        ]
        let original: [String: Any] = [
            "hooks": [
                "PreToolUse": [userHook],
                "PostToolUse": [userHook],
            ],
            "model": "sonnet-4.6",
        ]
        let installed = HookInstaller.install(into: original, bridgePath: bridgePath)
        let uninstalled = HookInstaller.uninstall(from: installed)

        // No marker entries left anywhere.
        XCTAssertFalse(HookInstaller.isInstalled(in: uninstalled, bridgePath: bridgePath))

        // User entries intact.
        let hooks = uninstalled["hooks"] as? [String: Any]
        let pre = hooks?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(pre?.count, 1)
        XCTAssertEqual(pre?.first?["matcher"] as? String, "Bash")

        // model still there.
        XCTAssertEqual(uninstalled["model"] as? String, "sonnet-4.6")
    }

    func testUninstallEmptyEventCleansUp() {
        // If an event ends up with no entries after our removal, the event key
        // should be deleted to keep the file tidy.
        let original: [String: Any] = [:]
        let installed = HookInstaller.install(into: original, bridgePath: bridgePath)
        let uninstalled = HookInstaller.uninstall(from: installed)
        // Hooks dict should be gone since every entry was ours.
        XCTAssertNil(uninstalled["hooks"])
    }

    func testUninstallNoOpWhenNotInstalled() {
        let original: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "*",
                        "hooks": [["type": "command", "command": "/usr/local/bin/foo"]],
                    ]
                ]
            ]
        ]
        let result = HookInstaller.uninstall(from: original)
        let hooks = result["hooks"] as? [String: Any]
        XCTAssertEqual((hooks?["PreToolUse"] as? [[String: Any]])?.count, 1,
                       "user entry must survive a no-op uninstall")
    }

    func testIsInstalledFalseForPathMismatch() {
        let installed = HookInstaller.install(into: [:], bridgePath: bridgePath)
        XCTAssertFalse(HookInstaller.isInstalled(in: installed, bridgePath: "/wrong/path"))
    }
}
