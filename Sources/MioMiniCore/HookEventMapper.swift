import Foundation

/// Pure mapping from a Claude Code hook payload (the JSON Claude Code feeds
/// to its hook scripts on stdin) into a normalized session payload that the app
/// understands. Keeping this pure makes it the most testable part of the bridge.
public enum HookEventMapper {
    /// Probe markers for third-party telemetry/CI sessions we should ignore.
    public static let probeMarkers: Set<String> = ["ClaudeProbe", "MioMiniProbe", "CodexBar"]

    public enum MapDecision: Equatable {
        /// Forward this payload to the app.
        case forward(payload: [String: AnyHashable])
        /// Do nothing; let Claude Code handle it natively.
        case dropSilently(reason: String)
    }

    /// Map a parsed hook input to either a payload to send or a silent drop.
    public static func map(rawInput raw: [String: Any], parentPID: Int32) -> MapDecision {
        let cwd = (raw["cwd"] as? String) ?? ""
        if probeMarkers.contains(where: { cwd.contains($0) }) {
            return .dropSilently(reason: "probe-marker")
        }
        let event = (raw["hook_event_name"] as? String) ?? ""

        // AskUserQuestion: never intercept — Claude Code shows its own picker.
        if event == "PermissionRequest", (raw["tool_name"] as? String) == "AskUserQuestion" {
            return .dropSilently(reason: "ask-user-question")
        }
        // Notification of permission_prompt: PermissionRequest carries richer info; skip dup.
        if event == "Notification", (raw["notification_type"] as? String) == "permission_prompt" {
            return .dropSilently(reason: "duplicate-permission-prompt")
        }

        let status = statusFor(event: event, raw: raw)
        var payload: [String: AnyHashable] = [
            "session_id": (raw["session_id"] as? String) ?? "unknown",
            "cwd": cwd,
            "event": event,
            "pid": Int(parentPID),
            "source": "claude_code",
            "status": status,
        ]
        if let toolName = raw["tool_name"] as? String {
            payload["tool"] = toolName
        }
        if let toolUseId = raw["tool_use_id"] as? String {
            payload["tool_use_id"] = toolUseId
        }
        if let toolInput = raw["tool_input"] as? [String: Any] {
            // Re-encode as canonical JSON string. The app side can parse this safely
            // and apply length limits (PRD SEC-6) before display.
            if let data = try? JSONSerialization.data(
                withJSONObject: toolInput,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ), let s = String(data: data, encoding: .utf8) {
                payload["tool_input_json"] = s
            }
        }
        if event == "Notification" {
            if let nt = raw["notification_type"] as? String {
                payload["notification_type"] = nt
            }
            if let m = raw["message"] as? String {
                payload["message"] = m
            }
        }
        return .forward(payload: payload)
    }

    public static func statusFor(event: String, raw: [String: Any]) -> String {
        switch event {
        case "UserPromptSubmit": return "processing"
        case "PreToolUse": return "running_tool"
        case "PostToolUse": return "processing"
        case "PermissionRequest": return "waiting_for_approval"
        case "Notification":
            let nt = raw["notification_type"] as? String
            return nt == "idle_prompt" ? "waiting_for_input" : "notification"
        case "Stop", "SubagentStop", "SessionStart": return "waiting_for_input"
        case "SessionEnd": return "ended"
        case "PreCompact": return "compacting"
        default: return "unknown"
        }
    }
}
