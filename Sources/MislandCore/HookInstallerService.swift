import Foundation

/// File-I/O wrapper around the pure `HookInstaller`. Owns reading and atomically
/// rewriting `~/.claude/settings.json`.
///
/// Safety invariants (PRD §6 SEC-4):
/// - Never silently overwrite a malformed settings.json. If JSON parsing fails
///   we throw `malformedSettings`, leaving the file untouched and forcing the
///   user to fix it (their custom config is precious).
/// - Always write atomically: serialize to temp, fsync via Foundation's
///   `Data.write(options: [.atomic])`, then rename. A power loss mid-write
///   leaves either the old file or the new file, never a half-written one.
/// - Empty file or missing file is treated as `{}` (Claude Code's default).
public final class HookInstallerService {
    public let settingsPath: String

    public init(settingsPath: String? = nil) {
        if let p = settingsPath {
            self.settingsPath = p
        } else {
            // Use NSHomeDirectory rather than ProcessInfo.environment["HOME"]
            // so sandboxed contexts (if we add an .app bundle later) resolve
            // to the right user dir.
            self.settingsPath = (NSHomeDirectory() as NSString)
                .appendingPathComponent(".claude/settings.json")
        }
    }

    /// Returns true if our hook entries are currently installed and pointing
    /// at the given bridge path.
    public func isInstalled(bridgePath: String) -> Bool {
        guard let s = try? readSettingsOrEmpty() else { return false }
        return HookInstaller.isInstalled(in: s, bridgePath: bridgePath)
    }

    /// Install (or re-install) our hook entries pointing at `bridgePath`.
    /// Idempotent: a second call replaces an existing entry rather than
    /// duplicating it.
    public func install(bridgePath: String) throws {
        let original = try readSettingsOrEmpty()
        let modified = HookInstaller.install(into: original, bridgePath: bridgePath)
        try writeSettingsAtomic(modified)
    }

    /// Remove only our hook entries; leave any user-defined hooks for the same
    /// events untouched.
    public func uninstall() throws {
        let original = try readSettingsOrEmpty()
        let modified = HookInstaller.uninstall(from: original)
        try writeSettingsAtomic(modified)
    }

    // MARK: - I/O

    func readSettingsOrEmpty() throws -> [String: Any] {
        let url = URL(fileURLWithPath: settingsPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            if let dict = obj as? [String: Any] { return dict }
            // Top-level is JSON but not an object — refuse to touch.
            throw HookInstallerServiceError.malformedSettings(path: settingsPath, detail: "top-level must be a JSON object")
        } catch let e as HookInstallerServiceError {
            throw e
        } catch {
            throw HookInstallerServiceError.malformedSettings(path: settingsPath, detail: error.localizedDescription)
        }
    }

    func writeSettingsAtomic(_ obj: [String: Any]) throws {
        let url = URL(fileURLWithPath: settingsPath)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: [.atomic])
    }
}

public enum HookInstallerServiceError: Error, Equatable {
    case malformedSettings(path: String, detail: String)
}
