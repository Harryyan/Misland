import SwiftUI
import MioMiniCore

/// SwiftUI content of the floating notch overlay.
///
/// Layout matches the MioIsland visual signature:
/// - Bar is centered on the physical notch (panel sits at screen.midX).
/// - Custom `NotchShape` gives the wings inward-curving top corners and
///   outward-rounded bottom corners — the wings appear to grow out of the
///   notch hardware itself.
/// - Notch hardware sits in the middle of the bar's footprint; the bar's
///   black background visually merges with the physical black notch.
/// - Left wing: status dot · buddy · status text.
/// - Right wing: agent badge · project name.
/// - Permission pending → bar grows downward into a drawer with PermissionPanel.
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
                if let pending = state.session.pendingPermission {
                    PermissionPanel(pending: pending) { decision in
                        state.decide(nonce: pending.envelopeNonce, decision: decision)
                    }
                    .colorScheme(.dark)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
        }
        .contextMenu {
            Button("Settings…") { openWindow(id: "settings") }
            Divider()
            Button("Quit Misland") { NSApplication.shared.terminate(nil) }
        }
    }

    /// The always-visible strip wrapping the notch. Three columns:
    /// left wing | notch reserve (where the hardware notch lives) | right wing.
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
                Text(projectName(from: cwd))
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
