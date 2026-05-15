import Foundation
import GhosttyTerminal

// Builds a TerminalTheme (which carries both light + dark variants) from
// a single hex color — the repo's identity color. libghostty swaps
// light vs. dark automatically with the system appearance, so per-repo
// glow follows macOS Light/Dark without us re-rendering.
//
// Approach: hand-pick a GitHub-Light-ish bright palette and a Tokyo-Night-
// ish dark palette, then tint each background ~10% toward the repo
// color so the surface has a soft glow that's recognisable at a glance
// while still leaving plenty of contrast for foreground text.
enum RepoThemeGenerator {

    static func theme(forProjectColor hex: String) -> TerminalTheme {
        let accent = RGB(hex: hex) ?? RGB(r: 0.5, g: 0.5, b: 0.5)
        return TerminalTheme(
            light: lightConfig(accent: accent),
            dark: darkConfig(accent: accent)
        )
    }

    // Cache key fragment. Theme generation is deterministic in the input
    // hex, so the TerminalRendererCache can use this to key per-repo
    // theme without serialising the whole TerminalTheme.
    static func cacheKey(forProjectColor hex: String) -> String {
        "gen:\(hex.lowercased())"
    }

    // MARK: - Light palette

    private static func lightConfig(accent: RGB) -> TerminalConfiguration {
        let baseBg = RGB(r: 0.98, g: 0.98, b: 0.98)
        let bg = baseBg.mixed(with: accent, t: 0.10).hex
        var c = TerminalConfiguration()
            .background(bg)
            .foreground("#1f2328")
            .cursorColor(accent.hex)
            .selectionBackground(accent.mixed(with: RGB(r: 1, g: 1, b: 1), t: 0.55).hex)
            .selectionForeground("#1f2328")
        // GitHub Light-style ANSI palette
        let lightPalette: [String] = [
            "#24292f", "#cf222e", "#116329", "#7d4e00",
            "#0969da", "#8250df", "#1b7c83", "#6e7781",
            "#57606a", "#a40e26", "#1a7f37", "#633c01",
            "#218bff", "#a475f9", "#3192aa", "#8c959f",
        ]
        for (i, color) in lightPalette.enumerated() {
            c = c.palette(i, color: color)
        }
        return c
    }

    // MARK: - Dark palette

    private static func darkConfig(accent: RGB) -> TerminalConfiguration {
        let baseBg = RGB(hex: "#0d1117") ?? RGB(r: 0.05, g: 0.07, b: 0.09)
        let bg = baseBg.mixed(with: accent, t: 0.10).hex
        var c = TerminalConfiguration()
            .background(bg)
            .foreground("#c9d1d9")
            .cursorColor(accent.hex)
            .selectionBackground(accent.mixed(with: RGB(r: 0, g: 0, b: 0), t: 0.55).hex)
            .selectionForeground("#c9d1d9")
        // Tokyo Night-ish ANSI palette
        let darkPalette: [String] = [
            "#15161e", "#f7768e", "#9ece6a", "#e0af68",
            "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
            "#414868", "#ff7a93", "#b9f27c", "#ff9e64",
            "#7da6ff", "#bb9af7", "#0db9d7", "#c0caf5",
        ]
        for (i, color) in darkPalette.enumerated() {
            c = c.palette(i, color: color)
        }
        return c
    }
}

// Simple RGB struct in [0,1] floats so we can mix without going through
// AppKit / SwiftUI Color (which would force the file into AppKit, while
// the generator output is libghostty-typed strings).
private struct RGB {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        self.r = Double((n >> 16) & 0xFF) / 255
        self.g = Double((n >> 8) & 0xFF) / 255
        self.b = Double(n & 0xFF) / 255
    }

    var hex: String {
        let ri = max(0, min(255, Int((r * 255).rounded())))
        let gi = max(0, min(255, Int((g * 255).rounded())))
        let bi = max(0, min(255, Int((b * 255).rounded())))
        return String(format: "#%02x%02x%02x", ri, gi, bi)
    }

    // Linear mix between two colors: t=0 returns self, t=1 returns other.
    func mixed(with other: RGB, t: Double) -> RGB {
        RGB(
            r: r + (other.r - r) * t,
            g: g + (other.g - g) * t,
            b: b + (other.b - b) * t
        )
    }
}
