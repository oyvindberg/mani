import SwiftUI
import ManiCore
import GhosttyTheme

// Sheet for picking a per-project terminal theme. Selecting "(use global
// default)" clears the override so terminal panes inherit the
// Settings.terminalTheme. Selecting any other entry dispatches
// .setProjectTheme. The picker shows curated favorites first, then an
// alphabetical browse of every theme libghostty ships (~485 total).
struct ProjectThemeSheet: View {
    let store: Store
    let project: Project
    @Binding var isPresented: Bool

    @State private var selection: String

    init(store: Store, project: Project, isPresented: Binding<Bool>) {
        self.store = store
        self.project = project
        self._isPresented = isPresented
        self._selection = State(initialValue: project.terminalTheme ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(SwiftUI.Color(hex: project.color))
                    .frame(width: 14, height: 14)
                Text("Theme for \(project.name)")
                    .font(.headline)
                Spacer()
            }
            Text("Applies to every terminal pane in this project's worktrees. Tasks already mounted will pick up the new theme the next time you switch to them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                Section {
                    Text("(use global default)").tag("")
                }
                Section("Favorites") {
                    ForEach(Self.curated, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Section("All themes") {
                    ForEach(Self.allThemes, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 320)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let theme: String? = selection.isEmpty ? nil : selection
                    Task {
                        await store.dispatch(.setProjectTheme(
                            id: project.id, theme: theme
                        ))
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
    }

    private static let curated: [String] = [
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

    // All theme names from the catalog, sorted, with the curated ones
    // filtered out so they don't appear twice in the list.
    private static let allThemes: [String] = {
        let curatedSet = Set(curated)
        return GhosttyThemeCatalog.search("")
            .map { $0.name }
            .filter { !curatedSet.contains($0) }
            .sorted()
    }()
}
