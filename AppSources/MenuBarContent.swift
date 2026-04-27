import SwiftUI
import MioMiniCore

struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let err = state.startupError {
                StartupErrorBanner(message: err)
            } else {
                statusBlock
                if let pending = state.session.pendingPermission {
                    PermissionPanel(pending: pending) { decision in
                        state.decide(nonce: pending.envelopeNonce, decision: decision)
                    }
                }
            }
            Divider()
            HStack {
                Button("Settings…") { openWindow(id: "settings") }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            BuddyView(species: state.selectedBuddy)
                .frame(width: 28, height: 28)
            Text("MioMini").font(.headline)
            if let source = state.session.source {
                AgentBadge(source: source)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: state.session.status.menuBarIconName)
                    .foregroundStyle(state.session.status.color)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cwd = state.session.cwd {
                Text(verbatim: cwd)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .truncationMode(.head)
                    .lineLimit(1)
            }
            if let tool = state.session.tool {
                Text("Tool: \(tool)").font(.caption)
            }
        }
    }

    private var statusLabel: LocalizedStringKey {
        switch state.session.status {
        case .idle:               return "idle"
        case .processing:         return "processing"
        case .runningTool:        return "running tool"
        case .waitingForApproval: return "needs approval"
        case .waitingForInput:    return "ready"
        case .compacting:         return "compacting"
        case .ended:              return "ended"
        case .notification:       return "notification"
        case .unknown:             return "unknown"
        }
    }
}

private struct AgentBadge: View {
    let source: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(badgeColor.opacity(0.4), lineWidth: 0.5))
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
        case "claude_code": return .orange
        case "gemini_cli":  return .blue
        default:            return .gray
        }
    }
}

private struct StartupErrorBanner: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MioMini couldn't start")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.tail)
        }
        .padding(8)
        .background(.red.opacity(0.1))
        .cornerRadius(6)
    }
}
