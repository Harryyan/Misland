import SwiftUI
import MislandCore

/// SwiftUI content of the floating notch overlay.
///
/// Two display modes:
/// - **Idle / no active sessions** — bare bar around the notch, no drawer.
/// - **Active** — bar + drawer below showing each tracked session row,
///   PLUS the permission panel on top when a session has a pending request.
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Tap to collapse / re-expand. Animated by SwiftUI;
                        // panel frame animation is driven by NSAnimationContext
                        // in NotchPanelController so they stay in sync.
                        withAnimation(.easeOut(duration: 0.32)) {
                            state.toggleManualCollapse()
                        }
                    }
                drawer
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.easeOut(duration: 0.32), value: state.session.pendingPermission?.envelopeNonce)
        .animation(.easeOut(duration: 0.32), value: state.displayableSessions.count)
        .animation(.easeOut(duration: 0.32), value: state.userCollapsed)
        .contextMenu {
            Button("Settings…") { openWindow(id: "settings") }
            Divider()
            Button("Quit Misland") { NSApplication.shared.terminate(nil) }
        }
    }

    /// The always-visible strip wrapping the notch.
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

    /// Drawer content. Empty / userCollapsed → drawer not rendered.
    @ViewBuilder
    private var drawer: some View {
        if let pending = state.session.pendingPermission {
            PermissionPanel(pending: pending) { decision in
                state.decide(nonce: pending.envelopeNonce, decision: decision)
            }
            .colorScheme(.dark)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else if !state.displayableSessions.isEmpty && !state.userCollapsed {
            SessionListDrawer()
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
            if let cwd = state.session.cwd {
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

// MARK: - Session list drawer

private struct SessionListDrawer: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            sessions
        }
        // Horizontal padding must exceed NotchShape.topCornerRadius (18) so
        // text and the gear icon don't bleed past the visible black region.
        // 28pt gives 10pt of breathing room beyond the curve inset.
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var header: some View {
        HStack {
            Text(verbatim: countLabel)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button {
                openWindow(id: "settings")
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
    }

    private var countLabel: String {
        let n = state.displayableSessions.count
        return n == 1 ? "1 session" : "\(n) sessions"
    }

    private var sessions: some View {
        VStack(spacing: 6) {
            ForEach(state.displayableSessions, id: \.sessionId) { session in
                SessionRow(session: session)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
                        removal: .opacity
                    ))
            }
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var state: AppState
    let session: SessionState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            BuddyView(species: state.selectedBuddy)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                titleLine
                subtitleLine
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                if let source = session.source {
                    AgentBadge(source: source)
                }
                ElapsedText(date: session.lastUpdate)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(verbatim: projectLabel)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let task = taskBlurb {
                Text(verbatim: " · \(task)")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var subtitleLine: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(session.status.color)
                .frame(width: 5, height: 5)
            Text(verbatim: statusBlurb)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    private var projectLabel: String {
        if let cwd = session.cwd {
            return (cwd as NSString).lastPathComponent
        }
        if let id = session.sessionId {
            return "session \(id.prefix(6))"
        }
        return "—"
    }

    /// Top-line task blurb. We don't yet capture the user's prompt, so use
    /// the current tool when running, or the human-readable status otherwise.
    private var taskBlurb: String? {
        if let tool = session.tool, !tool.isEmpty { return tool }
        return nil
    }

    private var statusBlurb: String {
        switch session.status {
        case .idle:               return "idle"
        case .processing:         return "processing"
        case .runningTool:        return session.tool.map { "running \($0)" } ?? "running tool"
        case .waitingForApproval: return "needs approval"
        case .waitingForInput:    return "ready"
        case .compacting:         return "compacting"
        case .ended:              return "ended"
        case .notification:       return "notification"
        case .unknown:            return "unknown"
        }
    }
}

private struct ElapsedText: View {
    let date: Date
    @State private var now = Date()

    var body: some View {
        Text(verbatim: format(now.timeIntervalSince(date)))
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) {
                now = $0
            }
    }

    private func format(_ secs: TimeInterval) -> String {
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86_400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86_400))d"
    }
}

// MARK: - Agent badge (used in both wing and rows)

struct AgentBadge: View {
    let source: String

    var body: some View {
        Text(verbatim: label)
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
