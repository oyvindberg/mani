import SwiftUI
import ManiCore
import GhosttyTheme

// macOS Preferences pane bound via `Settings { ... }` in ManiApp; opens with
// Cmd-, automatically. Per-knob design lives in docs/persistence.md
// "What lives in `Settings`".

struct SettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        TabView {
            generalForm.tabItem { Label("General", systemImage: "gear") }
            terminalForm.tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .frame(width: 480, height: 280)
    }

    private var generalForm: some View {
        Form {
            Section("Persistence") {
                let scrollbackBinding = Binding<Int>(
                    get: { store.state.settings.scrollbackCapBytes / (1024 * 1024) },
                    set: { newMB in
                        var s = store.state.settings
                        s.scrollbackCapBytes = max(1, newMB) * 1024 * 1024
                        Task { await store.dispatch(.updateSettings(s)) }
                    }
                )
                let intervalBinding = Binding<Int>(
                    get: { store.state.settings.snapshotIntervalSeconds },
                    set: { newSec in
                        var s = store.state.settings
                        s.snapshotIntervalSeconds = max(5, newSec)
                        Task { await store.dispatch(.updateSettings(s)) }
                    }
                )
                Stepper(
                    value: scrollbackBinding, in: 1...512,
                    label: { Text("Scrollback cap: \(scrollbackBinding.wrappedValue) MB per task") }
                )
                Stepper(
                    value: intervalBinding, in: 5...600, step: 5,
                    label: { Text("Snapshot every \(intervalBinding.wrappedValue) s") }
                )
            }
        }
        .formStyle(.grouped)
    }

    private var terminalForm: some View {
        Form {
            Section {
                let themeBinding = Binding<String>(
                    get: { store.state.settings.terminalTheme },
                    set: { name in
                        var s = store.state.settings
                        s.terminalTheme = name
                        Task { await store.dispatch(.updateSettings(s)) }
                    }
                )
                Picker("Theme", selection: themeBinding) {
                    ForEach(curatedThemes, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Text("Theme changes apply to terminal panes the next time they're mounted (switch tasks or close/reopen).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Appearance")
            }
        }
        .formStyle(.grouped)
    }

    // A curated subset from the GhosttyTheme catalog (485 total) — enough to
    // give the user choices without rendering 485 menu entries. The Picker
    // could grow into a search-as-you-type field if the list gets unwieldy.
    private var curatedThemes: [String] {
        [
            "Dracula",
            "Tokyo Night",
            "Tokyo Night Storm",
            "Solarized Dark - Patched",
            "Solarized Light",
            "Nord",
            "Gruvbox Dark",
            "GitHub Dark",
            "GitHub Light",
            "OneHalfDark",
            "OneHalfLight",
            "Catppuccin Mocha",
            "Catppuccin Latte",
            "Monokai Soda",
            "Builtin Solarized Dark",
        ].filter { GhosttyThemeCatalog.theme(named: $0) != nil }
    }
}
