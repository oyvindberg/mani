import SwiftUI

extension SwiftUI.Color {
    // Lenient: accepts "#rgb", "#rrggbb", "rgb", "rrggbb", with or without #.
    // Falls back to Color.gray for malformed input — Mani's per-project color
    // string is opaque to ManiCore (just a String), so the renderer must not
    // crash on bad data.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var r: Double = 0.5, g: Double = 0.5, b: Double = 0.5
        if s.count == 3 {
            let chars = Array(s)
            if let rv = Int(String(chars[0]), radix: 16),
               let gv = Int(String(chars[1]), radix: 16),
               let bv = Int(String(chars[2]), radix: 16) {
                r = Double(rv * 17) / 255
                g = Double(gv * 17) / 255
                b = Double(bv * 17) / 255
            }
        } else if s.count == 6 {
            if let rv = Int(s.prefix(2), radix: 16),
               let gv = Int(s.dropFirst(2).prefix(2), radix: 16),
               let bv = Int(s.dropFirst(4).prefix(2), radix: 16) {
                r = Double(rv) / 255
                g = Double(gv) / 255
                b = Double(bv) / 255
            }
        }
        self.init(red: r, green: g, blue: b)
    }
}
