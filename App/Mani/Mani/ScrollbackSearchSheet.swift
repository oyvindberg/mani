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

    struct Match: Identifiable, Equatable {
        let id = UUID()
        let lineNumber: Int
        let line: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search scrollback…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: query) { _, new in runSearch(query: new) }
                    .onSubmit { /* re-run for free via onChange */ }
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
                        Text(highlight(match.line))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(match.line, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy line")
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

    // Case-insensitive substring highlight using AttributedString. Lines
    // longer than ~400 chars are truncated in display via lineLimit but the
    // copied line is the original.
    private func highlight(_ line: String) -> AttributedString {
        var attr = AttributedString(stripANSI(line))
        guard !query.isEmpty else { return attr }
        let lowercase = String(attr.characters).lowercased()
        let needle = query.lowercased()
        var search = lowercase[lowercase.startIndex...]
        while let range = search.range(of: needle) {
            let nsRange = NSRange(range, in: lowercase)
            if let attrRange = Range(nsRange, in: attr) {
                attr[attrRange].backgroundColor = .yellow.opacity(0.4)
                attr[attrRange].foregroundColor = .black
            }
            search = lowercase[range.upperBound...]
        }
        return attr
    }

    private func stripANSI(_ s: String) -> String {
        Self.stripANSIstatic(s)
    }

    private func runSearch(query: String) {
        let path = scrollbackPath
        let cap = 500
        let needle = query
        Task.detached(priority: .userInitiated) {
            // Search across the current scrollback.log plus every rotated
            // scrollback-<unix>.log sibling, in chronological order. Line
            // numbers are global across the concatenated stream.
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
            let n = needle.lowercased()
            var matches: [Match] = []
            var lineNo = 0
            var truncatedFlag = false
            outer: for file in files {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                      let text = String(data: data, encoding: .utf8)
                else { continue }
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    lineNo += 1
                    // Strip ANSI BEFORE matching so cursor-positioning /
                    // color escapes don't break up the user's literal query.
                    // The displayed + copied line is also the stripped one
                    // (the raw line would be a mess of escape codes).
                    let stripped = Self.stripANSIstatic(String(line))
                    if stripped.lowercased().contains(n) {
                        matches.append(Match(lineNumber: lineNo, line: stripped))
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
