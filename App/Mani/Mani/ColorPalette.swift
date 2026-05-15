import SwiftUI

// docs/decisions.md ADR-009: hand-picked palette, 8–12 swatches, plus a free-
// form hex input. No auto-assignment — the user picks deliberately.

enum ColorPalette {
    // Picked for distinguishability on both light and dark macOS chrome,
    // accessible across common red/green colorblindness types (verified in
    // Sim Daltonism). Values stored as the same hex format that Repo.color
    // uses on disk.
    static let swatches: [String] = [
        "#e74c3c", // red
        "#f39c12", // orange
        "#f1c40f", // yellow
        "#2ecc71", // green
        "#1abc9c", // teal
        "#3498db", // blue
        "#5b6dcd", // indigo
        "#9b59b6", // purple
        "#e91e63", // pink
        "#8e6e53", // brown
        "#6c7a89", // slate
    ]
}

struct ColorSwatchPicker: View {
    @Binding var hex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 6),
                spacing: 6
            ) {
                ForEach(ColorPalette.swatches, id: \.self) { swatch in
                    Button {
                        hex = swatch
                    } label: {
                        ZStack {
                            Circle()
                                .fill(SwiftUI.Color(hex: swatch))
                                .frame(width: 24, height: 24)
                            if normalize(hex) == normalize(swatch) {
                                Circle()
                                    .stroke(SwiftUI.Color.primary, lineWidth: 2)
                                    .frame(width: 28, height: 28)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                Text("Hex")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("#rrggbb", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 110)
                Circle()
                    .fill(SwiftUI.Color(hex: hex))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(SwiftUI.Color.secondary.opacity(0.4)))
            }
        }
    }

    private func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !t.hasPrefix("#") { t = "#" + t }
        return t
    }
}
