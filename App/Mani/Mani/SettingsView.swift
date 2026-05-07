import SwiftUI
import ManiCore

// macOS Preferences pane bound via `Settings { ... }` in ManiApp; opens with
// Cmd-, automatically. Per-knob design lives in docs/persistence.md
// "What lives in `Settings`".

struct SettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        TabView {
            generalForm.tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 460, height: 220)
    }

    private var generalForm: some View {
        Form {
            Section("Persistence") {
                let scrollbackBinding = Binding<Int>(
                    get: { store.state.settings.scrollbackCapBytes / (1024 * 1024) },
                    set: { newMB in
                        let updated = Settings(
                            scrollbackCapBytes: max(1, newMB) * 1024 * 1024,
                            snapshotIntervalSeconds: store.state.settings.snapshotIntervalSeconds
                        )
                        Task { await store.dispatch(.updateSettings(updated)) }
                    }
                )
                let intervalBinding = Binding<Int>(
                    get: { store.state.settings.snapshotIntervalSeconds },
                    set: { newSec in
                        let updated = Settings(
                            scrollbackCapBytes: store.state.settings.scrollbackCapBytes,
                            snapshotIntervalSeconds: max(5, newSec)
                        )
                        Task { await store.dispatch(.updateSettings(updated)) }
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
}
