# MioMini — PRD v0.1

A macOS notch overlay for AI coding agent state. Claude Code: full control. Gemini CLI: read-only. Security-first. Single user, single machine.

Decisions locked 2026-04-27:
- Gemini CLI: read-only (no permission interception)
- Buddy: option A — 9 internal pixel characters, user picks one in Settings
- Codex CLI: not in v1

## Targets
- macOS 14.0+ (universal binary arm64 + x86_64)
- Single user, single machine
- Zero network out (Sparkle update + optional rate-limit polling only)

## Functional scope (v1)

| Module | In | Out |
|---|---|---|
| Notch state display | 5 status colors + current task title + timer; single most-active session | Multi-session list |
| Permission approval (Claude Code only) | Allow / Deny + tool args preview; 30s default-deny timeout | Per-dir whitelist, custom rules |
| Gemini CLI integration | Read-only: log/JSONL watcher → status | Permission interception |
| Sounds | 5 events × on/off + global mute + volume | User-uploaded sounds |
| Buddy | 9 built-in pixel characters; pick in Settings | Hash decoding of Claude's internal buddy |
| i18n | en + zh-Hans, follow system | Other languages |
| Settings | Display picker, login launch, sounds, buddy, hooks install/uninstall | Themes, layout editor, plugins |

## Architecture

```
Claude Code         Gemini CLI
   │                  │
   ▼ stdin (hook)     ▼ FSEvents on logs
miomini-hook (Swift CLI)   GeminiWatcher (in-app)
   │
   ▼ HMAC-signed line over Unix socket
   ~/Library/Application Support/MioMini/control.sock  (mode 0600)
   │
   ▼
MioMini.app (SwiftUI)
   ├─ NotchWindow
   ├─ SessionStore (single-session state machine)
   ├─ SoundPlayer (AVFoundation)
   └─ Settings (UserDefaults)
```

### Wire format (envelope)

Single-line JSON, newline-delimited:
```
{"v":1,"ts":"<ISO8601>","nonce":"<32 hex>","payload":<obj>,"mac":"<64 hex>"}
```
- `mac = HMAC-SHA256(key, "v=1;ts=<ts>;nonce=<n>;payload=" || canonical_json(payload))`
- `canonical_json` = `JSONSerialization` with `.sortedKeys + .withoutEscapingSlashes`
- Receiver rejects: bad MAC, |now − ts| > 30s, version mismatch

### Key management

- One 256-bit key per install at `~/Library/Application Support/MioMini/.secret`
- File mode 0600 enforced on read; refuse to load if any group/other bits are set
- `Settings → Reset Pairing` regenerates and forces hook re-install

## Security commitments (verifiable)

| ID | Requirement | How verified |
|---|---|---|
| SEC-1 | Socket under `~/Library/Application Support/MioMini/`, mode 0600 | `ls -l` |
| SEC-2 | All messages HMAC-signed; per-install random key in `.secret` (mode 0600) | Tamper test in CI |
| SEC-3 | Developer ID signed + Notarized; **no** auto-copy of self to `/Applications` | `codesign --verify` |
| SEC-4 | Hook install merges into `~/.claude/settings.json`, never overwrites | Round-trip test |
| SEC-5 | Permission panel default-Deny on 30s timeout (configurable 10–300) | Manual + sim |
| SEC-6 | Tool args truncated >4 KB; ANSI/HTML escaped before display | Fuzz test |
| SEC-7 | Zero outbound network in v1 except Sparkle update check | Little Snitch |
| SEC-8 | No reading of `claude` binary; no `~/.claude.json` writes | Static scan |
| SEC-9 | Accessibility permission optional; basic features work without | Manual |
| SEC-10 | License = MIT (decided 2026-04-27) | LICENSE file |

## Build & test

```bash
swift build
swift test
.build/debug/miomini-hook < /path/to/sample-hook-event.json
```

## Milestones

| Week | Goal |
|---|---|
| W1 | Hook bridge + secure socket + HMAC + HookInstaller merge-safe |
| W2 | Session state machine + notch collapsed view |
| W3 | Permission panel + 30s default-deny + arg sanitization |
| W4 | Gemini CLI log/JSONL watcher → status |
| W5 | 9 buddy assets + Settings UI + sounds + i18n |
| W6 | Developer ID sign + Notarize + Sparkle + private beta |
