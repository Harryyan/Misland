import XCTest
@testable import MioMiniCore

final class HookEventMapperTests: XCTestCase {
    func testProbeMarkerCwdIsDropped() {
        let raw: [String: Any] = ["cwd": "/tmp/ClaudeProbe", "hook_event_name": "Stop"]
        XCTAssertEqual(
            HookEventMapper.map(rawInput: raw, parentPID: 1),
            .dropSilently(reason: "probe-marker")
        )
    }

    func testAskUserQuestionPermissionDropped() {
        let raw: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "tool_name": "AskUserQuestion",
        ]
        XCTAssertEqual(
            HookEventMapper.map(rawInput: raw, parentPID: 1),
            .dropSilently(reason: "ask-user-question")
        )
    }

    func testPermissionPromptNotificationDropped() {
        let raw: [String: Any] = [
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
        ]
        XCTAssertEqual(
            HookEventMapper.map(rawInput: raw, parentPID: 1),
            .dropSilently(reason: "duplicate-permission-prompt")
        )
    }

    func testStatusMappingExhaustive() {
        let cases: [(String, String, [String: Any])] = [
            ("UserPromptSubmit", "processing", [:]),
            ("PreToolUse", "running_tool", [:]),
            ("PostToolUse", "processing", [:]),
            ("PermissionRequest", "waiting_for_approval", [:]),
            ("Stop", "waiting_for_input", [:]),
            ("SubagentStop", "waiting_for_input", [:]),
            ("SessionStart", "waiting_for_input", [:]),
            ("SessionEnd", "ended", [:]),
            ("PreCompact", "compacting", [:]),
            ("Notification", "waiting_for_input", ["notification_type": "idle_prompt"]),
            ("Notification", "notification", ["notification_type": "info"]),
            ("Garbage", "unknown", [:]),
        ]
        for (event, expected, extra) in cases {
            var raw: [String: Any] = ["hook_event_name": event]
            for (k, v) in extra { raw[k] = v }
            XCTAssertEqual(
                HookEventMapper.statusFor(event: event, raw: raw),
                expected,
                "event \(event) extra=\(extra)"
            )
        }
    }

    func testForwardCarriesEssentialFields() throws {
        let raw: [String: Any] = [
            "session_id": "sess-123",
            "cwd": "/Users/me/proj",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_use_id": "use-7",
            "tool_input": ["command": "ls"],
        ]
        guard case let .forward(payload) = HookEventMapper.map(rawInput: raw, parentPID: 4242) else {
            return XCTFail("expected forward")
        }
        XCTAssertEqual(payload["session_id"] as? String, "sess-123")
        XCTAssertEqual(payload["cwd"] as? String, "/Users/me/proj")
        XCTAssertEqual(payload["event"] as? String, "PreToolUse")
        XCTAssertEqual(payload["tool"] as? String, "Bash")
        XCTAssertEqual(payload["tool_use_id"] as? String, "use-7")
        XCTAssertEqual(payload["pid"] as? Int, 4242)
        XCTAssertEqual(payload["status"] as? String, "running_tool")
        XCTAssertEqual(payload["source"] as? String, "claude_code")
        // tool_input is re-encoded as a canonical JSON string.
        let tij = payload["tool_input_json"] as? String
        XCTAssertEqual(tij, #"{"command":"ls"}"#)
    }
}
