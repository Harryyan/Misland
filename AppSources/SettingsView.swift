import SwiftUI
import MioMiniCore

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var lastError: String?

    var body: some View {
        TabView {
            HookSettingsView(lastError: $lastError)
                .tabItem { Label("Hooks", systemImage: "link") }
            SoundSettingsView()
                .tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
            BuddySettingsView()
                .tabItem { Label("Buddy", systemImage: "face.smiling") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
    }
}

private struct HookSettingsView: View {
    @EnvironmentObject private var state: AppState
    @Binding var lastError: String?
    @State private var refreshTick: Int = 0

    private var bridgePath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/miomini-hook")
            .path
    }

    private var isInstalled: Bool {
        // refreshTick exists only to force recomputation after a button press.
        _ = refreshTick
        return state.isHookInstalled(bridgePath: bridgePath)
    }

    var body: some View {
        Form {
            Section("Claude Code hooks") {
                LabeledContent("Status") {
                    if isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not installed", systemImage: "circle.dashed")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Bridge path") {
                    Text(verbatim: bridgePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button(isInstalled ? "Re-install" : "Install hooks") {
                        do {
                            try state.installHooks(bridgePath: bridgePath)
                            lastError = nil
                        } catch {
                            lastError = "\(error)"
                        }
                        refreshTick += 1
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Uninstall") {
                        do {
                            try state.uninstallHooks()
                            lastError = nil
                        } catch {
                            lastError = "\(error)"
                        }
                        refreshTick += 1
                    }
                    .disabled(!isInstalled)
                }
                if let lastError {
                    Text(verbatim: lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Notes") {
                Text("Installation merges entries into ~/.claude/settings.json without touching your existing hooks. Uninstall removes only MioMini's entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct SoundSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Mute all sounds", isOn: $state.soundMuted)
            }
            Section("Per-event sounds") {
                ForEach(SoundEvent.allCases, id: \.self) { event in
                    Toggle(event.label, isOn: state.binding(for: event))
                        .disabled(state.soundMuted)
                }
            }
            Section {
                Button("Test current event sounds") { state.testAllSounds() }
                    .disabled(state.soundMuted)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct BuddySettingsView: View {
    @EnvironmentObject private var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 80), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(BuddySpecies.allCases, id: \.self) { species in
                    BuddyTile(species: species, isSelected: state.selectedBuddy == species) {
                        state.selectedBuddy = species
                    }
                }
            }
            .padding()
        }
    }
}

private struct BuddyTile: View {
    let species: BuddySpecies
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                BuddyView(species: species)
                    .frame(width: 48, height: 48)
                Text(LocalizedStringKey(species.displayName))
                    .font(.caption2)
            }
            .frame(width: 76, height: 76)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MioMini").font(.title2).bold()
            Text("v0.1.0 — privacy-first Claude Code state in your menu bar")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("• Local only. Zero outbound network.")
            Text("• HMAC-signed control socket; mode 0600.")
            Text("• Permission auto-deny after 30 s.")
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
