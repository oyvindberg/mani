import SwiftUI
import AppKit
import ManiCore

// Cmd-F overlay for the currently-selected job's terminal pane. libghostty
// has no API to jump-scroll its grid to a match, so we settle for showing
// matched lines from the on-disk scrollback file with their line numbers.
// Click → copy the line to the pasteboard. Useful for "find the thing I
// remember was 3000 lines back" without rolling a wheel.
struct ScrollbackSearchSheet: View {
    let scrollbackPath: String
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var results: [Match] = []
    @State private var totalLines: Int = 0
    @State private var truncated: Bool = false
    @State private var searchDebounce: DispatchWorkItem?

    struct Match: Identifiable, Equatable {
        let id = UUID()
        let lineNumber: Int
        let fullLine: String           // ANSI-stripped, full
        let snippet: String            // ~120-char window centered on the match
        let snippetMatchStart: Int     // offset of the match within `snippet`
        let snippetMatchLength: Int    // length (in characters) of the match
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
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(match.lineNumber)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 50, alignment: .trailing)
                        Text(snippetAttributed(match))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
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

    // Build a snippet of up to ~120 characters centered on the match
    // location within an already-stripped line. Adds leading/trailing
    // ellipses when truncated. Returns the snippet + the match's offset
    // and length inside it so the caller can highlight without re-scanning.
    private static func buildSnippet(
        line: String,
        matchStart: String.Index,
        matchEnd: String.Index
    ) -> (snippet: String, start: Int, length: Int) {
        let window = 120
        let lineCount = line.count
        let matchStartOffset = line.distance(from: line.startIndex, to: matchStart)
        let matchLen = line.distance(from: matchStart, to: matchEnd)
        // Compute window so the match sits roughly in the middle, then
        // clamp to the line's bounds.
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
        let path = scrollbackPath
        let cap = 200
        let needle = query
        Task.detached(priority: .userInitiated) {
            let files = Self.rotationChain(forCurrent: path)
            guard !needle.isEmpty else {
                let total = files.reduce(0) { $0 + Self.lineCount(at: $1) }
                await MainActor.run {
                    self.results = []
                    self.totalLines = total
                    self.truncated = false
                }
                return
            }
            let lowerNeedle = needle.lowercased()
            var matches: [Match] = []
            var lineNo = 0
            var truncatedFlag = false
            outer: for file in files {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                      let text = String(data: data, encoding: .utf8)
                else { continue }
                // Strip ANSI for the whole file once (cheaper than per-line)
                // and split. The split returns Substring views without
                // additional allocation.
                let stripped = Self.stripANSIstatic(text)
                for line in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
                    lineNo += 1
                    let lineLower = line.lowercased()
                    if let range = lineLower.range(of: lowerNeedle) {
                        // Map the lowercase-string range back to the original
                        // (same Unicode scalar count since lowercase doesn't
                        // change index distances for ASCII / most BMP).
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
                        matches.append(Match(
                            lineNumber: lineNo,
                            fullLine: lineStr,
                            snippet: snippet,
                            snippetMatchStart: off,
                            snippetMatchLength: len
                        ))
                        if matches.count >= cap {
                            truncatedFlag = true
                            break outer
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

    private static func stripANSIstatic(_ s: String) -> String {
        var out = ""
        var iter = s.unicodeScalars.makeIterator()
        while let c = iter.next() {
            if c.value == 0x1B {
                let next = iter.next()
                if next?.value == 0x5B {
                    while let n = iter.next() {
                        if (0x40...0x7E).contains(n.value) { break }
                    }
                } else if next?.value == 0x5D {
                    while let n = iter.next() {
                        if n.value == 0x07 { break }
                        if n.value == 0x1B { _ = iter.next(); break }
                    }
                }
                continue
            }
            if c.value >= 0x20 || c.value == 0x09 {
                out.unicodeScalars.append(c)
            }
        }
        return out
    }
}
