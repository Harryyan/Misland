import SwiftUI
import MislandCore

/// SwiftUI content of the floating notch overlay.
///
/// Three states:
/// - **Collapsed** (default): wings around the notch show the active session
///   only, with a `×N` badge if there are multiple sessions tracked.
/// - **Manually expanded** (user tapped the bar): a session list drops down
///   showing every Claude / Gemini session.
/// - **Permission expanded** (a session has a pendingPermission): the
///   PermissionPanel drops down. Takes priority over the manual list.
struct NotchView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    let geometry: NotchGeometry

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape()
                .fill(Color.black)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topStrip
                    .frame(height: geometry.notchHeight)
                    .contentShape(Rectangle())   // make entire strip tappable
                    .onTapGesture {
                        if state.session.pendingPermission == nil {
                            state.toggleManualExpansion()
                        }
                    }
                drawerContent
            }
        }
        .contextMenu {
            Button("Settings…") { openWindow(id: "settings") }
            Divider()
            Button("Quit Misland") { NSApplication.shared.terminate(nil) }
        }
    }

    private var topStrip: some View {
        HStack(spacing: 0) {
            LeftWing()
                .frame(maxWidth: .infinity)
            Color.clear
                .frame(width: geometry.notchWidth)
            RightWing()
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var drawerContent: some View {
        if let pending = state.session.pendingPermission {
            PermissionPanel(pending: pending) { decision in
                state.decide(nonce: pending.envelopeNonce, decision: decision)
            }
            .colorScheme(.dark)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else if state.isManuallyExpanded {
            SessionList()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }
}

private struct LeftWing: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Circle()
                .fill(state.session.status.color)
                .frame(width: 6, height: 6)
            BuddyView(species: state.selectedBuddy)
                .frame(width: 18, height: 18)
            Text(statusText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.trailing, 10)
    }

    private var statusText: LocalizedStringKey {
        switch state.session.status {
        case .idle:               return "idle"
        case .processing:         return "processing"
        case .runningTool:        return "running tool"
        case .waitingForApproval: return "needs approval"
        case .waitingForInput:    return "ready"
        case .compacting:         return "compacting"
        case .ended:              return "ended"
        case .notification:       return "notification"
        case .unknown:            return "unknown"
        }
    }
}

private struct RightWing: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            if state.allSessions.count > 1 {
                Text(verbatim: "×\(state.allSessions.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            } else if let cwd = state.session.cwd {
                Text(verbatim: projectName(from: cwd))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let source = state.session.source {
                AgentBadge(source: source)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
    }

    private func projectName(from path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

// MARK: - Session list (manual expansion)

private struct SessionList: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 6) {
            ForEach(state.allSessions, id: \.sessionId) { session in
                SessionRow(session: session)
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.status.color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: projectLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(verbatim: statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let source = session.source {
                AgentBadge(source: source)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var projectLabel: String {
        if let cwd = session.cwd {
            return (cwd as NSString).lastPathComponent
        }
        return session.sessionId.map { "session \($0.prefix(6))…" } ?? "—"
    }

    private var statusLine: String {
        var parts: [String] = []
        if let tool = session.tool { parts.append(tool) }
        parts.append(session.status.rawValue.replacingOccurrences(of: "_", with: " "))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Agent badge

struct AgentBadge: View {
    let source: String

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.25), in: Capsule())
            .overlay(Capsule().stroke(badgeColor.opacity(0.6), lineWidth: 0.5))
            .foregroundStyle(badgeColor)
    }

    private var label: String {
        switch source {
        case "claude_code": return "Claude"
        case "gemini_cli":  return "Gemini"
        default:            return source
        }
    }

    private var badgeColor: Color {
        switch source {
        case "claude_code": return Color(red: 1.0, green: 0.62, blue: 0.20)
        case "gemini_cli":  return Color(red: 0.30, green: 0.65, blue: 1.0)
        default:            return .gray
        }
    }
}
