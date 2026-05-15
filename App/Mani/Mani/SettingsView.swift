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
        .frame(width: 500, height: 380)
    }

    private var generalForm: some View {
        Form {
            Section("Persistence") {
                let scrollbackBinding = Binding<Int>(
                    get: { store.state.settings.scrollbackCapBytes / (1024 * 1024) },
                    set: { newMB in
                        var s = store.state.settings
                        s.scrollbackCapBytes = max(1, newMB) * 1024 * 1024
                        _Concurrency.Task { await store.dispatch(.updateSettings(s)) }
                    }
                )
                let intervalBinding = Binding<Int>(
                    get: { store.state.settings.snapshotIntervalSeconds },
                    set: { newSec in
                        var s = store.state.settings
                        s.snapshotIntervalSeconds = max(5, newSec)
                        _Concurrency.Task { await store.dispatch(.updateSettings(s)) }
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
            Section {
                let invocationBinding = Binding<String>(
                    get: { store.state.settings.claudeInvocation },
                    set: { value in
                        var s = store.state.settings
                        s.claudeInvocation = value
                        _Concurrency.Task { await store.dispatch(.updateSettings(s)) }
                    }
                )
                TextField("Command", text: invocationBinding, prompt: Text("claude"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Typed into a fresh /bin/zsh -l after spawn. `--resume <sid>` is appended automatically when resuming. Override per project from the sidebar context menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Claude command")
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
                        _Concurrency.Task { await store.dispatch(.updateSettings(s)) }
                    }
                )
                Picker("Theme", selection: themeBinding) {
                    ForEach(curatedThemes, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }

                let fontBinding = Binding<String>(
                    get: {
                        let f = store.state.settings.terminalFontFamily
                        return f.isEmpty ? "(libghostty default)" : f
                    },
                    set: { name in
                        var s = store.state.settings
                        s.terminalFontFamily = (name == "(libghostty default)") ? "" : name
                        _Concurrency.Task { await store.dispatch(.updateSettings(s)) }
                    }
                )
                Picker("Font", selection: fontBinding) {
                    Text("(libghostty default)").tag("(libghostty default)")
                    ForEach(curatedFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }

                let sizeBinding = Binding<Int>(
                    get: { store.state.settings.terminalFontSize },
                    set: { newSize in
                        var s = store.state.settings
                        s.terminalFontSize = max(8, min(48, newSize))
                        _Concurrency.Task { await store.dispatch(.updateSettings(s)) }
                    }
                )
                Stepper(
                    value: sizeBinding, in: 8...48,
                    label: { Text("Font size: \(sizeBinding.wrappedValue) pt") }
                )

                Text("Appearance changes apply to terminal panes the next time they're mounted (switch tasks or close/reopen).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Appearance")
            }
        }
        .formStyle(.grouped)
    }

    // Curated list of fonts likely to be installed on a developer Mac.
    // The user picks "(libghostty default)" to fall back to libghostty's
    // built-in font selection.
    private var curatedFonts: [String] {
        [
            "SF Mono",
            "Menlo",
            "Monaco",
            "Courier New",
            "Andale Mono",
            "Fira Code",
            "JetBrains Mono",
            "Hack",
            "MonoLisa",
            "IBM Plex Mono",
            "Cascadia Code",
            "Iosevka",
        ]
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
