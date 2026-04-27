import Foundation
import MioMiniCore
import Darwin

// miomini-hook
//
// Reads a Claude Code hook event JSON from stdin, signs it with the per-install
// HMAC key, and writes the envelope to the control socket. For PermissionRequest
// it waits for a signed reply and emits the Claude Code hook protocol response
// on stdout. All failure paths exit 0 with no stdout — Claude Code is allowed
// to fall back to its native UI.

let permissionRecvTimeout: TimeInterval = 300  // upper bound; app default-denies sooner

@inline(__always)
func silentExit(_ code: Int32 = 0) -> Never {
    exit(code)
}

// 1. Read stdin.
let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard !stdinData.isEmpty else { silentExit() }

guard let raw = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] else {
    silentExit()
}

// 2. Map to normalized payload (or drop).
let decision = HookEventMapper.map(rawInput: raw, parentPID: getppid())
guard case let .forward(hashablePayload) = decision else {
    silentExit()
}

let payload: [String: Any] = hashablePayload.reduce(into: [:]) { acc, kv in
    acc[kv.key] = kv.value
}

// 3. Load (or create) the per-install key.
let key: HMACKey
do {
    key = try HMACKey.loadOrCreate()
} catch {
    silentExit()
}

// 4. Sign envelope.
let envelope: SocketEnvelope
do {
    envelope = try SocketEnvelope.sign(payload: payload, key: key)
} catch {
    silentExit()
}

let isPermission = (payload["status"] as? String) == SessionStatus.waitingForApproval.rawValue

// 5. Connect to the socket server. If unavailable, exit silently — fail-open-to-CC.
let socketPath = ProcessInfo.processInfo.environment["MIOMINI_SOCKET_PATH"] ?? SecurityPaths.socketPath

let fd: Int32
do {
    fd = try UnixSocket.connectClient(
        path: socketPath,
        sendTimeout: 5,
        recvTimeout: isPermission ? permissionRecvTimeout : 1
    )
} catch {
    silentExit()
}
defer { Darwin.close(fd) }

// 6. Encode line and send.
do {
    var line = try envelope.encode()
    line.append(0x0a)
    try UnixSocket.writeAll(fd: fd, data: line)
} catch {
    silentExit()
}

// 7. For non-permission events: done.
if !isPermission {
    silentExit()
}

// 8. For PermissionRequest: wait for a signed reply.
let replyData: Data
do {
    replyData = try UnixSocket.readLine(fd: fd)
} catch {
    // Server closed without responding (or app crashed) — fall through to Claude Code's UI.
    silentExit()
}

let replyEnvelope: SocketEnvelope
do {
    replyEnvelope = try SocketEnvelope.verify(
        rawJSON: replyData,
        key: key,
        maxAgeSeconds: permissionRecvTimeout + 10
    )
} catch {
    // Tampered or stale reply — refuse to act on it. Fall through to CC's UI.
    silentExit()
}

let decisionStr = (replyEnvelope.payload["decision"] as? String) ?? "ask"
let reason = (replyEnvelope.payload["reason"] as? String) ?? ""

let output: [String: Any]
switch decisionStr {
case "allow":
    output = [
        "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "allow"],
        ]
    ]
case "deny":
    output = [
        "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": [
                "behavior": "deny",
                "message": reason.isEmpty ? "Denied by user via MioMini" : reason,
            ],
        ]
    ]
default:
    silentExit()
}

if let data = try? JSONSerialization.data(withJSONObject: output) {
    FileHandle.standardOutput.write(data)
}
silentExit()
