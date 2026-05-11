import SwiftUI
import AppKit
import ManiCore

// Cmd-F overlay for the currently-selected job's terminal pane. libghostty
// has no API to jump-scroll its grid to a match, so we settle for showing
// matched lines from the on-disk scrollback file with their line numbers.
// Click → copy the line to the pasteboard. Useful for "find the thing I
// remember was 3000 lines back" without rolling a wheel.
struct ScrollbackSearchSheet: View {
    // One source per Mani job — its display label (project › worktree › name)
    // plus the on-disk scrollback file. Multiple sources mean the search is
    // cross-task; the result row shows which source the match belongs to.
    struct Source {
        let label: String
        let scrollbackPath: String
    }

    let sources: [Source]
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var results: [Match] = []
    @State private var totalLines: Int = 0
    @State private var truncated: Bool = false
    @State private var searchDebounce: DispatchWorkItem?

    struct Match: Identifiable, Equatable {
        let id = UUID()
        let sourceLabel: String        // which task this came from
        let lineNumber: Int
        let fullLine: String           // ANSI-stripped, full
        let snippet: String            // line starting at column 0, truncated
        let snippetMatchStart: Int     // offset of the match within `snippet`
        let snippetMatchLength: Int    // length (in characters) of the match
        let nextLine: String?          // ANSI-stripped, up to 160 chars
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search scrollback…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: query) { _, new in scheduleSearch(new) }
                Spacer()
                Text("\(results.count) match\(results.count == 1 ? "" : "es")"
                     + (truncated ? " (truncated)" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            if query.isEmpty {
                placeholder
            } else if results.isEmpty {
                Text("No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { match in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(match.lineNumber)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 50, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.sourceLabel)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(snippetAttributed(match))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let next = match.nextLine, !next.isEmpty {
                                Text(next)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(match.fullLine, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy full line")
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.bordered)
            }
        }
        .frame(width: 720, height: 480)
        .onAppear { runSearch(query: query) }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Type to search this task's scrollback.")
                .foregroundStyle(.secondary)
            if totalLines > 0 {
                Text("\(totalLines) lines indexed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Highlight just the match window inside the snippet. The snippet
    // is already sized + centered on the match by buildSnippet, so we
    // only need to colorize the known range.
    private func snippetAttributed(_ match: Match) -> AttributedString {
        var attr = AttributedString(match.snippet)
        let start = attr.characters.index(
            attr.startIndex,
            offsetBy: max(0, match.snippetMatchStart),
            limitedBy: attr.endIndex
        ) ?? attr.endIndex
        let end = attr.characters.index(
            start,
            offsetBy: match.snippetMatchLength,
            limitedBy: attr.endIndex
        ) ?? attr.endIndex
        if start < end {
            attr[start..<end].backgroundColor = .yellow.opacity(0.45)
            attr[start..<end].foregroundColor = .black
        }
        return attr
    }

    // Build a snippet that starts at the BEGINNING of the line (no
    // leading ellipsis), goes up to `window` characters. If the match
    // ends after the window, we extend just enough to keep the match
    // visible plus a small trailing context, separated from the prefix
    // by " … ". Highlight offset is updated to match.
    private static func buildSnippet(
        line: String,
        matchStart: String.Index,
        matchEnd: String.Index
    ) -> (snippet: String, start: Int, length: Int) {
        let window = 240
        let trailContext = 30
        let lineCount = line.count
        let matchStartOffset = line.distance(from: line.startIndex, to: matchStart)
        let matchLen = line.distance(from: matchStart, to: matchEnd)
        let matchEndOffset = matchStartOffset + matchLen

        if matchEndOffset <= window {
            // Match fits in the prefix window.
            let endOffset = min(window, lineCount)
            let endIdx = line.index(line.startIndex, offsetBy: endOffset)
            var snippet = String(line[..<endIdx])
            if endOffset < lineCount { snippet += "…" }
            return (snippet, matchStartOffset, matchLen)
        } else {
            // Match is past the prefix window: show first ~80 chars, then
            // " … ", then the match plus a little trailing context.
            let prefixLen = min(80, lineCount)
            let prefixEnd = line.index(line.startIndex, offsetBy: prefixLen)
            let prefix = String(line[..<prefixEnd])
            let contextStart = max(prefixLen, matchStartOffset - 10)
            let contextEnd = min(lineCount, matchEndOffset + trailContext)
            let cs = line.index(line.startIndex, offsetBy: contextStart)
            let ce = line.index(line.startIndex, offsetBy: contextEnd)
            let bridge = " … "
            var snippet = prefix + bridge + String(line[cs..<ce])
            if contextEnd < lineCount { snippet += "…" }
            let snippetMatchOffset = prefix.count + bridge.count
                                   + (matchStartOffset - contextStart)
            return (snippet, snippetMatchOffset, matchLen)
        }
    }

    private func stripANSI(_ s: String) -> String {
        Self.stripANSIstatic(s)
    }

    // Debounce keystrokes: typing fires onChange once per char which would
    // dispatch one Task per char. 150 ms feels responsive; below that you
    // can outrun the search on a multi-MB scrollback.
    private func scheduleSearch(_ q: String) {
        searchDebounce?.cancel()
        let work = DispatchWorkItem { runSearch(query: q) }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func runSearch(query: String) {
        let needle = query
        let cap = 200
        let allSources = sources
        Task.detached(priority: .userInitiated) {
            guard !needle.isEmpty else {
                var total = 0
                for src in allSources {
                    for f in Self.rotationChain(forCurrent: src.scrollbackPath) {
                        total += Self.lineCount(at: f)
                    }
                }
                await MainActor.run {
                    self.results = []
                    self.totalLines = total
                    self.truncated = false
                }
                return
            }
            let lowerNeedle = needle.lowercased()
            var matches: [Match] = []
            var truncatedFlag = false
            sourceLoop: for src in allSources {
                let files = Self.rotationChain(forCurrent: src.scrollbackPath)
                var lineNo = 0
                for file in files {
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                          let text = String(data: data, encoding: .utf8)
                    else { continue }
                    let stripped = Self.stripANSIstatic(text)
                    let lines = Array(
                        stripped.split(separator: "\n", omittingEmptySubsequences: false)
                    )
                    for (idx, line) in lines.enumerated() {
                        lineNo += 1
                        let lineLower = line.lowercased()
                        guard let range = lineLower.range(of: lowerNeedle) else { continue }
                        let lineStr = String(line)
                        guard let mappedStart = lineStr.index(
                            lineStr.startIndex,
                            offsetBy: lineLower.distance(from: lineLower.startIndex, to: range.lowerBound),
                            limitedBy: lineStr.endIndex
                        ),
                        let mappedEnd = lineStr.index(
                            mappedStart,
                            offsetBy: lineLower.distance(from: range.lowerBound, to: range.upperBound),
                            limitedBy: lineStr.endIndex
                        ) else { continue }
                        let (snippet, off, len) = Self.buildSnippet(
                            line: lineStr,
                            matchStart: mappedStart,
                            matchEnd: mappedEnd
                        )
                        // Trim the next line to 160 chars so the search row
                        // doesn't blow up vertically with a long context line.
                        let next: String?
                        if idx + 1 < lines.count {
                            let raw = String(lines[idx + 1])
                            next = String(raw.prefix(160))
                        } else {
                            next = nil
                        }
                        matches.append(Match(
                            sourceLabel: src.label,
                            lineNumber: lineNo,
                            fullLine: lineStr,
                            snippet: snippet,
                            snippetMatchStart: off,
                            snippetMatchLength: len,
                            nextLine: next
                        ))
                        if matches.count >= cap {
                            truncatedFlag = true
                            break sourceLoop
                        }
                    }
                }
            }
            let final = matches
            let truncOut = truncatedFlag
            await MainActor.run {
                self.results = final
                self.truncated = truncOut
            }
        }
    }

    // Sibling rotation chain: every scrollback-<unix>.log in the same dir
    // as `current`, sorted oldest-to-newest by filename suffix, with the
    // current scrollback.log appended at the end. Missing files are
    // tolerated — the user might never have hit rotation.
    private static func rotationChain(forCurrent current: String) -> [String] {
        let url = URL(fileURLWithPath: current)
        let dir = url.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let rotated = contents
            .filter { $0.hasPrefix("scrollback-") && $0.hasSuffix(".log") }
            .sorted()
        return rotated.map { dir.appendingPathComponent($0).path } + [current]
    }

    private static func lineCount(at path: String) -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return 0 }
        return data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    }

    // Convert raw PTY bytes to plain text suitable for display + substring
    // search. TUIs like Ink and powerline prompts lay out content using
    // cursor-positioning escapes (`\033[<col>H`, `\033[NC`) rather than
    // literal spaces, so naively dropping CSI sequences makes words
    // collide (e.g. "Nopre-commitenforcement" instead of "No pre-commit
    // enforcement"). Heuristic:
    //   - CSI ending in 'm' (SGR / color): drop silently, no padding.
    //   - CSI ending in 'C' (cursor forward N): emit N spaces.
    //   - Any other CSI (H/f/J/K/A/B/D/G/...): emit one space.
    //   - OSC sequences: drop entirely (titles, hyperlinks etc.).
    // Not a real terminal emulator — multi-line cursor moves are not
    // tracked — but for line-scoped scrollback search it's a big upgrade.
    private static func stripANSIstatic(_ s: String) -> String {
        var out = ""
        var iter = s.unicodeScalars.makeIterator()
        while let c = iter.next() {
            if c.value == 0x1B {
                let next = iter.next()
                if next?.value == 0x5B { // CSI
                    var params = ""
                    var finalLetter: UInt32 = 0
                    while let n = iter.next() {
                        if (0x40...0x7E).contains(n.value) {
                            finalLetter = n.value
                            break
                        }
                        params.unicodeScalars.append(n)
                    }
                    switch finalLetter {
                    case 0x6D: // 'm' SGR
                        break
                    case 0x43: // 'C' cursor forward
                        // Take the first parameter (semicolon-separated),
                        // default 1. Clamp to a sane max so a hostile
                        // payload can't blow up the output buffer.
                        let n = params.split(separator: ";").first
                            .flatMap { Int($0) } ?? 1
                        out.append(String(repeating: " ", count: max(0, min(n, 200))))
                    default:
                        out.append(" ")
                    }
                } else if next?.value == 0x5D { // OSC
                    while let n = iter.next() {
                        if n.value == 0x07 { break }
                        if n.value == 0x1B { _ = iter.next(); break }
                    }
                }
                continue
            }
            // Drop control chars except tab; \r (0x0D) becomes a no-op
            // so re-render-via-CR doesn't smush content together.
            if c.value >= 0x20 || c.value == 0x09 {
                out.unicodeScalars.append(c)
            }
        }
        return out
    }
}
