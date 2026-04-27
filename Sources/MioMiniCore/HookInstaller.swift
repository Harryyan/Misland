import Foundation

/// Merge / unmerge MioMini's Claude Code hook entries into the user's
/// `~/.claude/settings.json` without touching anything the user has put there.
///
/// Strategy
/// --------
/// Every entry we add carries a marker key `_miomini_managed: true`. On
/// uninstall we filter out only entries with that marker, leaving any user-defined
/// hooks for the same event intact. Schema-wise Claude Code's hook config is
/// permissive about extra keys on the matcher group — we are not adding fields
/// to the inner `hooks` array element that Claude Code actually executes.
///
/// All operations are pure: caller reads the file, calls these functions, writes
/// the result back atomically.
public enum HookInstaller {
    public static let managedMarker = "_miomini_managed"

    /// Events we hook. Mirrors `HookEventMapper`'s vocabulary.
    public static let managedEvents: [String] = [
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "Notification",
        "Stop",
        "SubagentStop",
        "SessionStart",
        "SessionEnd",
        "PreCompact",
    ]

    /// Returns a new settings dict with our hook entries installed.
    /// Re-installing is idempotent: any prior managed entry is replaced, so the
    /// path can be updated without leaving duplicates.
    public static func install(into settings: [String: Any], bridgePath: String) -> [String: Any] {
        var out = settings
        var hooks = (out["hooks"] as? [String: Any]) ?? [:]
        for event in managedEvents {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            entries.removeAll { isManaged($0) }
            entries.append(makeManagedEntry(bridgePath: bridgePath))
            hooks[event] = entries
        }
        out["hooks"] = hooks
        return out
    }

    /// Returns a new settings dict with our hook entries removed.
    /// User-defined entries for the same events are preserved.
    public static func uninstall(from settings: [String: Any]) -> [String: Any] {
        var out = settings
        guard var hooks = out["hooks"] as? [String: Any] else { return out }
        for event in managedEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { isManaged($0) }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        if hooks.isEmpty {
            out.removeValue(forKey: "hooks")
        } else {
            out["hooks"] = hooks
        }
        return out
    }

    /// True if our hook entries are fully present and pointing at `bridgePath`.
    public static func isInstalled(in settings: [String: Any], bridgePath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for event in managedEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            let managed = entries.first { isManaged($0) }
            guard let m = managed else { return false }
            guard let inner = m["hooks"] as? [[String: Any]],
                  let cmd = inner.first?["command"] as? String,
                  cmd == bridgePath
            else { return false }
        }
        return true
    }

    // MARK: - Internals

    private static func isManaged(_ entry: [String: Any]) -> Bool {
        (entry[managedMarker] as? Bool) == true
    }

    private static func makeManagedEntry(bridgePath: String) -> [String: Any] {
        [
            "matcher": "*",
            "hooks": [
                ["type": "command", "command": bridgePath]
            ],
            managedMarker: true,
        ]
    }
}
