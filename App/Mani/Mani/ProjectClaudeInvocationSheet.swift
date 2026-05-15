import SwiftUI
import ManiCore

// Per-project override for the `claude` command typed into the spawned
// shell. Empty / whitespace-only string clears the override and falls
// back to Settings.claudeInvocation (Preferences → General).
struct ProjectClaudeInvocationSheet: View {
    let store: Store
    let project: Project
    @Binding var isPresented: Bool

    @State private var text: String
    @State private var overrideEnabled: Bool

    init(store: Store, project: Project, isPresented: Binding<Bool>) {
        self.store = store
        self.project = project
        self._isPresented = isPresented
        let initial = project.claudeInvocation
        self._text = State(initialValue: initial ?? "")
        self._overrideEnabled = State(initialValue: initial != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(SwiftUI.Color(hex: project.color))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
                Text("Claude command for \(project.name)")
                    .font(.headline)
                Spacer()
            }

            Toggle("Override the global Claude command", isOn: $overrideEnabled)

            TextField(
                "Command",
                text: $text,
                prompt: Text(store.state.settings.claudeInvocation)
            )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(!overrideEnabled)

            Text("Typed into a fresh /bin/zsh -l after spawn. `--resume <sid>` is appended automatically when resuming a past session. Leave this off to fall back to the global setting (\(store.state.settings.claudeInvocation)).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let next: String? = overrideEnabled && !trimmed.isEmpty ? trimmed : nil
                    _Concurrency.Task {
                        await store.dispatch(.setProjectClaudeInvocation(
                            id: project.id, invocation: next
                        ))
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var hasChanges: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = overrideEnabled && !trimmed.isEmpty ? trimmed : nil
        return next != project.claudeInvocation
    }
}
