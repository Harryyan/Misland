import SwiftUI
import MislandCore

/// Shown when `SessionStore` has a pending permission request. Args are run
/// through `ArgSanitizer.sanitize()` (PRD SEC-6) before display so ANSI escapes
/// and control chars can't break the UI.
struct PermissionPanel: View {
    let pending: PendingPermission
    let onDecision: (PermissionDecision) -> Void

    private var sanitizedArgs: String? {
        pending.toolInputJSON.map { ArgSanitizer.sanitize($0, maxBytes: 1_024) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(pending.tool)
                    .font(.system(.subheadline, design: .default).weight(.semibold))
                Spacer()
                TimeoutCounter(receivedAt: pending.receivedAt)
            }
            if let args = sanitizedArgs {
                ScrollView {
                    Text(args)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 100)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            HStack {
                Button("Deny") { onDecision(.deny) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow") { onDecision(.allow) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Tiny "expires in 30s" counter. The auto-deny fires server-side via
/// PermissionTimeoutCoordinator regardless of whether this view is on screen —
/// this counter is purely informational.
private struct TimeoutCounter: View {
    let receivedAt: Date
    @State private var now: Date = Date()

    private static let totalSeconds: TimeInterval = 30

    private var remaining: Int {
        let left = Self.totalSeconds - now.timeIntervalSince(receivedAt)
        return max(0, Int(left.rounded(.up)))
    }

    var body: some View {
        Text("\(remaining)s")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(remaining < 10 ? .red : .secondary)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { t in
                now = t
            }
    }
}
