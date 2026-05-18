import SwiftUI

// "Standing by." — the global Alfred-style overlay that lists
// every Claude session Mani knows about, grouped by status:
//   READY    — output waiting for you (Stop hook fired, or
//              unread > 0 and not currently thinking)
//   WORKING  — actively streaming bytes right now
//   IDLE     — alive but quiet (no unread, not thinking)
//
// Each row is one claude. Status drives the orb visual: ready
// orbs breathe in repo color; working orbs send out concentric
// ripples; idle orbs sit as a dim presence dot.
//
// This file is the pure SwiftUI view. The NSPanel host, global
// hotkey, and live-data subscription live in StandingByPanel.swift.

// MARK: - Data snapshot

enum ClaudeStatus: String, CaseIterable, Equatable {
    case ready
    case working
    case idle

    var label: String {
        switch self {
        case .ready:   return "ready"
        case .working: return "working"
        case .idle:    return "idle"
        }
    }
}

struct StandingByEntry: Identifiable, Equatable {
    let id: String          // backing claude session id
    let taskId: UUID
    let repoName: String
    let projectName: String
    let repoColor: SwiftUI.Color
    let preview: String?
    let status: ClaudeStatus
    let timestamp: Date     // sort key inside each section + age display
}

// MARK: - Root

struct StandingByView: View {
    let entries: [StandingByEntry]
    @Binding var focusedEntryId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                EmptyStandingBy()
            } else {
                StandingByHeader(counts: counts)
                    .padding(.bottom, 24)

                VStack(alignment: .leading, spacing: 18) {
                    section(.ready)
                    section(.working)
                    section(.idle)
                }
                .padding(.bottom, 22)

                KeyboardHint(focusedEntryName: focusedEntry?.projectName)
            }
        }
        .padding(.top, 30)
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
        .frame(width: 620)
        .background(
            ZStack {
                VisualEffectView(
                    material: .hudWindow,
                    blendingMode: .behindWindow
                )
                SwiftUI.Color.black.opacity(0.10)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(SwiftUI.Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: SwiftUI.Color.black.opacity(0.5), radius: 40, y: 12)
    }

    @ViewBuilder
    private func section(_ status: ClaudeStatus) -> some View {
        let rows = entries.filter { $0.status == status }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(status: status, count: rows.count)
                    .padding(.bottom, 4)
                ForEach(rows) { entry in
                    EntryRow(
                        entry: entry,
                        isFocused: focusedEntryId == entry.id
                    )
                }
            }
        }
    }

    private var counts: [ClaudeStatus: Int] {
        var out: [ClaudeStatus: Int] = [:]
        for entry in entries {
            out[entry.status, default: 0] += 1
        }
        return out
    }

    private var focusedEntry: StandingByEntry? {
        guard let id = focusedEntryId else { return nil }
        return entries.first(where: { $0.id == id })
    }
}

// MARK: - Header

private struct StandingByHeader: View {
    let counts: [ClaudeStatus: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Standing by.")
                .font(.system(size: 38, design: .serif).italic())
                .foregroundStyle(.primary)
                .tracking(-0.5)
            Text(subtitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        for status in ClaudeStatus.allCases {
            let n = counts[status] ?? 0
            if n > 0 {
                parts.append("\(spelled(n)) \(status.label)")
            }
        }
        return parts.isEmpty ? "no claudes" : parts.joined(separator: "  ·  ")
    }

    private func spelled(_ n: Int) -> String {
        switch n {
        case 1:  return "one"
        case 2:  return "two"
        case 3:  return "three"
        case 4:  return "four"
        case 5:  return "five"
        case 6:  return "six"
        case 7:  return "seven"
        case 8:  return "eight"
        case 9:  return "nine"
        case 10: return "ten"
        default: return "\(n)"
        }
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let status: ClaudeStatus
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(status.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(statusColor)
            Text("\(count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(SwiftUI.Color.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 4)
    }

    private var statusColor: SwiftUI.Color {
        switch status {
        case .ready:   return SwiftUI.Color.white.opacity(0.7)
        case .working: return SwiftUI.Color.white.opacity(0.45)
        case .idle:    return SwiftUI.Color.white.opacity(0.30)
        }
    }
}

// MARK: - Entry row

private struct EntryRow: View {
    let entry: StandingByEntry
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            StatusOrb(status: entry.status, color: entry.repoColor)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 17, design: .serif).weight(.semibold))
                    .tracking(-0.2)
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let preview = entry.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 12)

            AgeLabel(date: entry.timestamp)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isFocused
                        ? entry.repoColor.opacity(0.10)
                        : SwiftUI.Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    entry.repoColor.opacity(isFocused ? 0.30 : 0),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .leading) {
            // Repo-color spine on the left so the eye can group
            // rows from the same repo without reading text.
            Rectangle()
                .fill(entry.repoColor.opacity(spineOpacity))
                .frame(width: 2)
                .padding(.vertical, 4)
        }
        .shadow(
            color: isFocused
                ? entry.repoColor.opacity(0.22)
                : SwiftUI.Color.clear,
            radius: isFocused ? 16 : 0,
            y: 0
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private var label: String {
        entry.repoName + "  —  " + entry.projectName
    }

    private var primaryTextColor: SwiftUI.Color {
        switch entry.status {
        case .ready:   return .primary
        case .working: return .primary
        case .idle:    return .secondary
        }
    }

    private var spineOpacity: Double {
        switch entry.status {
        case .ready:   return 0.85
        case .working: return 0.6
        case .idle:    return 0.25
        }
    }
}

// MARK: - Status orb

// One orb per row. Visual treatment changes by status:
//   .ready    — full-brightness slow breath (2.6s cycle, halo)
//   .working  — concentric ripples emit from a core dot at 1.4s
//                intervals, giving the impression of active output
//   .idle     — small dim static dot, no animation
private struct StatusOrb: View {
    let status: ClaudeStatus
    let color: SwiftUI.Color

    var body: some View {
        switch status {
        case .ready:
            BreathingOrb(color: color)
        case .working:
            WorkingOrb(color: color)
        case .idle:
            IdleOrb(color: color)
        }
    }
}

// MARK: - Ready: breathing orb

// Slow asymmetric breath: 1.6s rise, 1.0s settle. Halo behind the
// orb extends with a 5pt blur for depth.
private struct BreathingOrb: View {
    let color: SwiftUI.Color

    private static let cycleDuration: Double = 2.6
    private static let riseDuration: Double = 1.6
    private static let orbDiameter: CGFloat = 12
    private static let haloDiameter: CGFloat = 20

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let cycle = (t / Self.cycleDuration)
                .truncatingRemainder(dividingBy: 1.0)
            let alpha = Self.orbOpacity(forCyclePos: cycle)
            ZStack {
                Circle()
                    .fill(color.opacity(alpha * 0.4))
                    .frame(width: Self.haloDiameter, height: Self.haloDiameter)
                    .blur(radius: 5)
                Circle()
                    .fill(color.opacity(alpha))
                    .frame(width: Self.orbDiameter, height: Self.orbDiameter)
            }
            .frame(width: Self.haloDiameter, height: Self.haloDiameter)
        }
    }

    private static func orbOpacity(forCyclePos cycle: Double) -> Double {
        let risePortion = riseDuration / cycleDuration
        let minAlpha = 0.45
        let span = 1.0 - minAlpha
        if cycle < risePortion {
            let t = cycle / risePortion
            return minAlpha + easeInOut(t) * span
        } else {
            let t = (cycle - risePortion) / (1.0 - risePortion)
            return minAlpha + (1.0 - easeInOut(t)) * span
        }
    }

    private static func easeInOut(_ t: Double) -> Double {
        3 * t * t - 2 * t * t * t
    }
}

// MARK: - Working: ripple orb

// Solid bright core + two ripples that expand and fade out, offset
// by half a cycle. The continuous emission reads as "active output
// landing right now."
private struct WorkingOrb: View {
    let color: SwiftUI.Color

    private static let cycleDuration: Double = 1.4
    private static let coreDiameter: CGFloat = 8
    private static let rippleMax: CGFloat = 22

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let cycle1 = (t / Self.cycleDuration)
                .truncatingRemainder(dividingBy: 1.0)
            let cycle2 = ((t / Self.cycleDuration) + 0.5)
                .truncatingRemainder(dividingBy: 1.0)
            ZStack {
                ripple(at: cycle1)
                ripple(at: cycle2)
                Circle()
                    .fill(color.opacity(0.95))
                    .frame(width: Self.coreDiameter, height: Self.coreDiameter)
            }
            .frame(width: Self.rippleMax, height: Self.rippleMax)
        }
    }

    @ViewBuilder
    private func ripple(at cycle: Double) -> some View {
        // Ripple grows from coreDiameter to rippleMax over the
        // cycle, alpha fading from 0.55 → 0 with easeOut so the
        // edge fades into the panel.
        let diameter = Self.coreDiameter
            + (Self.rippleMax - Self.coreDiameter) * CGFloat(cycle)
        let alpha = 0.55 * (1.0 - cycle * cycle)
        Circle()
            .strokeBorder(color.opacity(alpha), lineWidth: 1)
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - Idle: dim presence dot

private struct IdleOrb: View {
    let color: SwiftUI.Color

    var body: some View {
        Circle()
            .fill(color.opacity(0.25))
            .frame(width: 6, height: 6)
            .frame(width: 20, height: 20)  // align with other orb sizes
    }
}

// MARK: - Age label

private struct AgeLabel: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 10)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(date))
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Self.numericPart(of: elapsed))")
                    .font(.system(size: 12, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                Text(Self.unitPart(of: elapsed))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static func numericPart(of seconds: Double) -> Int {
        if seconds < 60   { return max(1, Int(seconds.rounded())) }
        if seconds < 3600 { return Int(seconds / 60) }
        return Int(seconds / 3600)
    }

    private static func unitPart(of seconds: Double) -> String {
        if seconds < 60   { return "s" }
        if seconds < 3600 { return "m" }
        return "h"
    }
}

// MARK: - Keyboard hint footer

private struct KeyboardHint: View {
    let focusedEntryName: String?

    var body: some View {
        HStack(spacing: 18) {
            hint(keys: "↑↓",  label: "navigate")
            hint(keys: "↵",   label: openLabel)
            hint(keys: "⌥↵",  label: "open (stay)")
            hint(keys: "esc", label: "dismiss")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private var openLabel: String {
        if let name = focusedEntryName {
            return "open " + name
        }
        return "open"
    }

    private func hint(keys: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .foregroundStyle(.tertiary)
                .fontWeight(.medium)
            Text(label)
                .foregroundStyle(.quaternary)
        }
    }
}

// MARK: - Empty state

private struct EmptyStandingBy: View {
    var body: some View {
        VStack(spacing: 22) {
            Text("Nothing pending.")
                .font(.system(size: 32, design: .serif).italic())
                .foregroundStyle(.secondary)
                .tracking(-0.3)
            Text("go make something.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

// MARK: - Preview

#if DEBUG
private struct StandingByPreview: View {
    @State private var focusedId: String?
    let entries: [StandingByEntry]

    var body: some View {
        StandingByView(
            entries: entries,
            focusedEntryId: $focusedId
        )
        .onAppear {
            focusedId = entries.first?.id
        }
        .padding(40)
        .frame(width: 760, height: 700)
        .background(SwiftUI.Color(white: 0.08))
        .preferredColorScheme(.dark)
    }
}

#Preview("Populated") {
    let mani = SwiftUI.Color(red: 0.55, green: 0.85, blue: 0.50)
    let dlab = SwiftUI.Color(red: 0.95, green: 0.65, blue: 0.20)
    let typr = SwiftUI.Color(red: 0.65, green: 0.45, blue: 0.90)
    let now = Date()
    return StandingByPreview(entries: [
        StandingByEntry(
            id: "sid-1", taskId: UUID(),
            repoName: "mani", projectName: "auth rewrite",
            repoColor: mani,
            preview: "implement the validator function and add tests",
            status: .ready,
            timestamp: now.addingTimeInterval(-540)
        ),
        StandingByEntry(
            id: "sid-2", taskId: UUID(),
            repoName: "dlab", projectName: "bleep CI cache",
            repoColor: dlab,
            preview: "investigate why the cache key keeps invalidating",
            status: .ready,
            timestamp: now.addingTimeInterval(-720)
        ),
        StandingByEntry(
            id: "sid-3", taskId: UUID(),
            repoName: "typr", projectName: "refactor tui",
            repoColor: typr,
            preview: "wire the TUI panel into the React tree",
            status: .working,
            timestamp: now.addingTimeInterval(-8)
        ),
        StandingByEntry(
            id: "sid-4", taskId: UUID(),
            repoName: "mani", projectName: "fix tests",
            repoColor: mani,
            preview: "running the test suite",
            status: .working,
            timestamp: now.addingTimeInterval(-3)
        ),
        StandingByEntry(
            id: "sid-5", taskId: UUID(),
            repoName: "mani", projectName: "doc helper",
            repoColor: mani,
            preview: "document the new helper in docs/auth.md",
            status: .idle,
            timestamp: now.addingTimeInterval(-7200)
        ),
        StandingByEntry(
            id: "sid-6", taskId: UUID(),
            repoName: "dlab", projectName: "slides deck",
            repoColor: dlab,
            preview: nil,
            status: .idle,
            timestamp: now.addingTimeInterval(-18000)
        ),
    ])
}

#Preview("Empty") {
    StandingByPreview(entries: [])
}
#endif
