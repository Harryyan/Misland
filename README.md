# Misland

A privacy-first macOS notch overlay that surfaces what Claude Code and Gemini CLI are doing — so you don't have to keep flipping back to the terminal.

> **Form factor (v0.1):** a borderless `NSPanel` anchored to the screen-top
> notch on notched MacBooks. The panel wraps the notch with two "wings" that
> show status + buddy + project name; tap to expand a drawer of tracked
> sessions, or to surface a permission panel when Claude Code asks for
> approval. On non-notched displays the overlay still draws, anchored to
> the same screen-top region.

```
[●] Misland  Claude                    needs approval
─────────────────────────────────────────────────────
/Users/me/projects/api
Tool: Bash
┌───────────────────────────────────────┐
│ ⚠️  Bash                       28s  │
│  ┌──────────────────────────────────┐ │
│  │ {"command":"rm -rf /tmp/cache"}  │ │
│  └──────────────────────────────────┘ │
│  Deny                          Allow  │
└───────────────────────────────────────┘
```

**Status:** v0.1 alpha. Single-developer project, ad-hoc signed. Use at your own risk.

## What it does

- **Claude Code** — full integration via the official hook protocol. See current state, get an approval panel for every `PermissionRequest`, auto-deny after 30 s of no decision.
- **Gemini CLI** — read-only. FSEvents-based watcher infers activity from file changes in known Gemini data directories; no permission interception (Gemini CLI lacks the protocol for it).
- **Buddy** — pick one of 9 hand-drawn pixel companions. Lives in the menu bar dropdown header.
- **Sounds** — 5 events, system sounds, individually toggleable.
- **i18n** — English, 简体中文 (auto-detect from system).

## What it explicitly does not do (v0.1)

- ❌ Cloud sync, iPhone companion, plugin marketplace, remote launch
- ❌ Any outbound network in v1 except Sparkle update check (when configured)
- ❌ Reading the `claude` binary or hashing internals
- ❌ Auto-installing copies of itself anywhere

## Security model

| Concern | What we do |
|---|---|
| Local IPC | AF_UNIX socket at `~/Library/Application Support/Misland/`, mode 0600 + per-install random HMAC key, per-message HMAC-SHA256 + nonce + freshness, peer UID check |
| Replay attacks | TTL nonce cache; same envelope can't fire twice |
| ANSI / control chars in tool args | Stripped before display (tool args could otherwise hijack terminal-aware text views) |
| Stale prompts | Server auto-denies after 30 s if you haven't clicked anything |
| `~/.claude/settings.json` | Merged in; existing user hooks preserved; uninstall removes only our entries |

Full threat model in [PRD.md](PRD.md) §6.

> **Note on internal module naming:** the Swift package is called `MislandCore`,
> the bridge binary `misland-hook`, and the support directory
> `~/Library/Application Support/Misland/`. These are internal codenames left
> over from the project's working title and are kept stable for backwards
> compatibility with already-paired hook installs. The user-facing app and
> repo are named **Misland**.

## Install (developer build)

Requires macOS 14+, Xcode 15+, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/Harryyan/Misland.git
cd Misland
xcodegen generate
open Misland.xcodeproj
```

Cmd+R in Xcode to launch. The notch overlay appears at the top of your
primary display. Right-click the bar to open **Settings → Hooks → Install
hooks** and wire up Claude Code.

## Usage

1. **Install hooks** in Settings. This merges entries into `~/.claude/settings.json`.
2. **Restart Claude Code** so it re-reads its settings.
3. Use Claude Code normally. The status dot in the notch bar turns:
   - 🔵 cyan — processing
   - 🟠 orange — needs your approval (the permission panel slides down + 30 s timer)
   - 🟢 green — ready / done

Gemini CLI: just use it. If your data dir is one of `~/.gemini`, `~/.config/gemini`, `~/.config/google/gemini`, Misland will pick it up. Otherwise set `MISLAND_GEMINI_DIR=/your/path` before launching the app.

## Architecture

```
Claude Code         Gemini CLI
   │                  │
   ▼ stdin (hook)     ▼ FSEvents on data dir
misland-hook (Swift CLI)   GeminiActivityWatcher (in-app)
   │
   ▼ HMAC-signed line over ~/Library/.../control.sock (mode 0600)
   │
   ▼
Misland.app
   ├─ HookSocketServer              verifies envelope, dedups nonce, dispatches to store
   ├─ SessionStore                  multi-session state machine (claude > gemini priority)
   ├─ PermissionTimeoutCoordinator  per-session timers, auto-deny after 30 s
   ├─ NotchPanelController          borderless NSPanel anchored to the notch
   └─ SwiftUI NotchView + Settings WindowGroup
```

`MislandCore` (SwiftPM library) holds all business logic — Foundation + CryptoKit + Darwin POSIX, no AppKit. The bridge CLI links only Core (~1 MB binary, <30 ms cold start). The app links Core + AppKit/SwiftUI.

## Development

```bash
swift test           # 108 unit + integration tests, ~4 s
swift build          # bridge CLI only
xcodegen generate    # regenerate Xcode project from project.yml
xcodebuild -scheme Misland build   # full app
```

## Roadmap

- [x] W1 — Hook bridge + secure socket
- [x] W2 — SessionStore + HookSocketServer + replay defense
- [x] W3 — Permission panel + 30s default-deny + arg sanitization
- [x] W4 — Gemini CLI activity watcher
- [x] W5 — Settings UI, sounds, i18n, pixel buddies
- [x] **Notch overlay** — borderless `NSPanel` anchored to the screen-top notch with expand/collapse drawer (the original Misland vision)
- [x] Multi-session permission timers (independent per-session 30s countdown)
- [ ] W6 — Sparkle auto-update, Developer ID + Notarize
- [ ] User-configurable permission timeout (PRD says 10–300 s; backend supports it, Settings UI doesn't expose it yet)
- [ ] Better pixel art for the 9 buddies
- [ ] Graceful fallback / behavior on non-notched displays

## License

[MIT](LICENSE)

## Inspiration

The notch-as-status-bar idea is borrowed from [MioIsland](https://github.com/MioMioOS/MioIsland) by xmqywx. Misland intentionally trades MioIsland's full feature set (iPhone sync, plugin marketplace, terminal jumping) for a smaller, more security-conscious surface area.
