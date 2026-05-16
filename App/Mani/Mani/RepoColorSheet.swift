import SwiftUI
import ManiCore

// Repo color is THE theming knob now — terminal panes derive a
// generated light + dark theme from this color (see
// RepoThemeGenerator). No theme name to pick; you just choose a
// color and the terminal background gets a soft glow of it that
// flips with the system appearance.
struct RepoColorSheet: View {
    let store: Store
    let repo: Repo
    @Binding var isPresented: Bool

    @State private var color: String

    init(store: Store, repo: Repo, isPresented: Binding<Bool>) {
        self.store = store
        self.repo = repo
        self._isPresented = isPresented
        self._color = State(initialValue: repo.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(SwiftUI.Color(hex: color))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
                Text("Color for \(repo.name)")
                    .font(.headline)
                Spacer()
            }
            Text("This color tints both the sidebar identity and the terminal background — about 10% mixed into a light or dark base. Pick something distinctive; macOS Light/Dark mode switches the base automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460, alignment: .leading)

            ColorSwatchPicker(hex: $color)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    _Concurrency.Task {
                        await store.dispatch(.setRepoColor(
                            id: repo.id, color: color
                        ))
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(color == repo.color)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
