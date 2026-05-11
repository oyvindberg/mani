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

        // Line 2 in the card: matched line from column 0, truncated.
        let snippet: String
        let snippetMatchStart: Int     // -1 if match is past the truncation
        let snippetMatchLength: Int

        // Line 3 in the card. Either the "… <match context> …" window if
        // the match was off-screen on line 2, OR the next file line if
        // the match was visible. nil if neither applies (match visible
        // AND no next line in the file).
        let thirdLine: String?
        let thirdMatchStart: Int       // -1 if line 3 is the next-line context (no highlight)
        let thirdMatchLength: Int
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
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(results) { match in
                            resultCard(match)
                        }
                    }
                    .padding(8)
                }
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

    // Each match is a three-line card:
    //   1. project › worktree › task (with line number prefix)
    //   2. matched line, starting at column 0, highlight if visible
    //   3. next line, if there is one
    // Card has a subtle background + border so a list of matches reads
    // as discrete blocks instead of squashed rows.
    private func resultCard(_ match: Match) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Header: line# + task path + copy button
            HStack(spacing: 6) {
                Text("\(match.lineNumber)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(match.sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            // Line 2: matched line from start
            Text(snippetAttributed(match))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Line 3: either match context (off-screen match) or next file line
            if let third = match.thirdLine, !third.isEmpty {
                Text(thirdAttributed(match))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(SwiftUI.Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(SwiftUI.Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func thirdAttributed(_ match: Match) -> AttributedString {
        guard let third = match.thirdLine else { return AttributedString("") }
        var attr = AttributedString(third)
        guard match.thirdMatchStart >= 0 else { return attr }
        let start = attr.characters.index(
            attr.startIndex,
            offsetBy: match.thirdMatchStart,
            limitedBy: attr.endIndex
        ) ?? attr.endIndex
        let end = attr.characters.index(
            start,
            offsetBy: match.thirdMatchLength,
            limitedBy: attr.endIndex
        ) ?? attr.endIndex
        if start < end {
            attr[start..<end].backgroundColor = .yellow.opacity(0.45)
            attr[start..<end].foregroundColor = .black
        }
        return attr
    }

    // Highlight the match window inside the snippet. If start == -1 the
    // match is past the snippet's truncation point — return the plain
    // snippet so the user still sees the line identity without a fake
    // highlight on the wrong characters.
    private func snippetAttributed(_ match: Match) -> AttributedString {
        var attr = AttributedString(match.snippet)
        guard match.snippetMatchStart >= 0 else { return attr }
        let start = attr.characters.index(
            attr.startIndex,
            offsetBy: match.snippetMatchStart,
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

    // A "… <match> …" window of ~280 characters centered on the match.
    // Used as the third line of a card when the matched line itself was
    // too long for the match to be visible in the start-anchored snippet.
    private static func buildContextWindow(
        line: String,
        matchStart: String.Index,
        matchEnd: String.Index
    ) -> (snippet: String, start: Int, length: Int) {
        let window = 280
        let lineCount = line.count
        let matchStartOffset = line.distance(from: line.startIndex, to: matchStart)
        let matchLen = line.distance(from: matchStart, to: matchEnd)
        var lo = max(0, matchStartOffset - (window - matchLen) / 2)
        var hi = min(lineCount, lo + window)
        if hi - lo < window { lo = max(0, hi - window) }
        let leadingEllipsis = lo > 0
        let trailingEllipsis = hi < lineCount
        let startIdx = line.index(line.startIndex, offsetBy: lo)
        let endIdx = line.index(line.startIndex, offsetBy: hi)
        var snippet = String(line[startIdx..<endIdx])
        var matchOffsetInSnippet = matchStartOffset - lo
        if leadingEllipsis {
            snippet = "…" + snippet
            matchOffsetInSnippet += 1
        }
        if trailingEllipsis { snippet += "…" }
        return (snippet, matchOffsetInSnippet, matchLen)
    }

    // Snippet starts at column 0 of the line, truncates to `window`
    // characters with a trailing ellipsis. The match offset/length are
    // returned only when the match fits inside the snippet — otherwise
    // start = -1 and the caller renders the snippet without highlight.
    private static func buildSnippet(
        line: String,
        matchStart: String.Index,
        matchEnd: String.Index
    ) -> (snippet: String, start: Int, length: Int) {
        let window = 280
        let lineCount = line.count
        let matchStartOffset = line.distance(from: line.startIndex, to: matchStart)
        let matchLen = line.distance(from: matchStart, to: matchEnd)
        let matchEndOffset = matchStartOffset + matchLen
        let endOffset = min(window, lineCount)
        let endIdx = line.index(line.startIndex, offsetBy: endOffset)
        var snippet = String(line[..<endIdx])
        if endOffset < lineCount { snippet += "…" }
        let highlightVisible = matchEndOffset <= endOffset
        return (
            snippet,
            highlightVisible ? matchStartOffset : -1,
            highlightVisible ? matchLen : 0
        )
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
                        // Third line: prefer match context if the match
                        // didn't fit in line 2, otherwise fall back to
                        // the next line of the file (truncated).
                        let third: String?
                        let thirdOff: Int
                        let thirdLen: Int
                        if off < 0 {
                            let (ctx, ctxOff, ctxLen) = Self.buildContextWindow(
                                line: lineStr,
                                matchStart: mappedStart,
                                matchEnd: mappedEnd
                            )
                            third = ctx
                            thirdOff = ctxOff
                            thirdLen = ctxLen
                        } else if idx + 1 < lines.count {
                            let raw = String(lines[idx + 1])
                            third = String(raw.prefix(280))
                            thirdOff = -1
                            thirdLen = 0
                        } else {
                            third = nil
                            thirdOff = -1
                            thirdLen = 0
                        }
                        matches.append(Match(
                            sourceLabel: src.label,
                            lineNumber: lineNo,
                            fullLine: lineStr,
                            snippet: snippet,
                            snippetMatchStart: off,
                            snippetMatchLength: len,
                            thirdLine: third,
                            thirdMatchStart: thirdOff,
                            thirdMatchLength: thirdLen
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
