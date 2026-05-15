import Foundation

// Looks up Claude Code session JSONL files under ~/.claude/repos/<slug>/
// for a given cwd. Mostly the same parsing logic as Spikes/JSONLSpike, but
// stops once it has the few fields the resume picker needs (id, cwd, first
// user message, last timestamp, message count). Sorted most-recent-first.

enum ClaudeHistoryScanner {

    struct Session {
        let id: String
        let path: URL
        let cwd: String?
        let firstUserMessage: String?
        let lastMessageAt: Date?
        let messageCount: Int
    }

    // Recent message preview: role + truncated text snippet + timestamp.
    // Used by the External Claude detail view to show "the last things
    // said" without dumping the entire transcript.
    struct RecentMessage: Identifiable {
        let id = UUID()
        let role: String     // "user" | "assistant" | "system" | etc.
        let text: String
        let timestamp: Date?
    }

    // Full pass over the JSONL that captures the rolling-window tail of
    // user/assistant messages plus the first user message. Heavy for
    // multi-megabyte transcripts but only invoked when the detail pane
    // mounts. The caller should dispatch onto a background queue.
    static func detail(jsonl: URL, recentLimit: Int) -> (Session, [RecentMessage])? {
        guard let stream = InputStream(url: jsonl) else { return nil }
        stream.open()
        defer { stream.close() }

        var sid: String?
        var cwd: String?
        var firstUserContent: String?
        var lastTs: Date?
        var msgCount = 0
        // Ring buffer of the last `recentLimit` messages
        var recent: [RecentMessage] = []

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var partial = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            partial.append(buf, count: n)
            while let nlIdx = partial.firstIndex(of: 0x0A) {
                let line = partial.subdata(in: 0..<nlIdx)
                partial.removeSubrange(0...nlIdx)
                processForDetail(
                    line: line, sid: &sid, cwd: &cwd,
                    firstUserContent: &firstUserContent,
                    lastTs: &lastTs, msgCount: &msgCount,
                    recent: &recent, limit: recentLimit,
                    formatter: formatter
                )
            }
        }
        if !partial.isEmpty {
            processForDetail(
                line: partial, sid: &sid, cwd: &cwd,
                firstUserContent: &firstUserContent,
                lastTs: &lastTs, msgCount: &msgCount,
                recent: &recent, limit: recentLimit,
                formatter: formatter
            )
        }

        guard let sid else { return nil }
        let session = Session(
            id: sid, path: jsonl, cwd: cwd,
            firstUserMessage: firstUserContent,
            lastMessageAt: lastTs,
            messageCount: msgCount
        )
        return (session, recent)
    }

    private static func processForDetail(
        line: Data,
        sid: inout String?,
        cwd: inout String?,
        firstUserContent: inout String?,
        lastTs: inout Date?,
        msgCount: inout Int,
        recent: inout [RecentMessage],
        limit: Int,
        formatter: ISO8601DateFormatter
    ) {
        if line.isEmpty { return }
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        if sid == nil, let s = json["sessionId"] as? String { sid = s }
        if cwd == nil, let c = json["cwd"] as? String { cwd = c }
        let type = json["type"] as? String
        let ts: Date? = (json["timestamp"] as? String).flatMap { formatter.date(from: $0) }
        guard type == "user" || type == "assistant" else { return }
        msgCount += 1
        if let ts { lastTs = ts }

        // Extract a text snippet for the message.
        var snippet = ""
        if let msg = json["message"] as? [String: Any] {
            if let s = msg["content"] as? String {
                snippet = s
            } else if let arr = msg["content"] as? [[String: Any]] {
                for block in arr {
                    if let text = block["text"] as? String {
                        snippet += (snippet.isEmpty ? "" : "\n") + text
                    } else if let blockType = block["type"] as? String {
                        // Tool-use blocks etc. Mark briefly so context is
                        // still legible.
                        if snippet.isEmpty { snippet = "[\(blockType)]" }
                    }
                }
            }
        }

        if firstUserContent == nil, type == "user", !snippet.isEmpty {
            firstUserContent = String(snippet.prefix(140))
        }

        let trimmed = snippet
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(300)
        recent.append(RecentMessage(
            role: type ?? "?", text: String(trimmed), timestamp: ts
        ))
        if recent.count > limit { recent.removeFirst(recent.count - limit) }
    }

    // Exposed for SafekeepingSweepWorker, which already has the URL
    // in hand (it's iterating ~/.claude/repos directly) and just
    // wants the same summary as sessions(forCwd:) produces per file.
    static func parsePublic(jsonl: URL) -> Session? {
        parse(jsonl: jsonl)
    }

    static func sessions(forCwd cwd: String) -> [Session] {
        // Claude's slug convention: leading dash, then path with `/` → `-`.
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let slug = "-" + trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/repos").appendingPathComponent(slug)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { parse(jsonl: $0) }
            .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    }

    private static func parse(jsonl: URL) -> Session? {
        guard let stream = InputStream(url: jsonl) else { return nil }
        stream.open()
        defer { stream.close() }

        var sid: String?
        var cwd: String?
        var firstUserContent: String?
        var lastTs: Date?
        var msgCount = 0

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var partial = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            partial.append(buf, count: n)
            while let nlIdx = partial.firstIndex(of: 0x0A) {
                let line = partial.subdata(in: 0..<nlIdx)
                partial.removeSubrange(0...nlIdx)
                consume(line: line, sid: &sid, cwd: &cwd,
                        firstUserContent: &firstUserContent,
                        lastTs: &lastTs, msgCount: &msgCount,
                        formatter: formatter)
            }
        }
        if !partial.isEmpty {
            consume(line: partial, sid: &sid, cwd: &cwd,
                    firstUserContent: &firstUserContent,
                    lastTs: &lastTs, msgCount: &msgCount,
                    formatter: formatter)
        }

        guard let sid else { return nil }
        return Session(
            id: sid, path: jsonl, cwd: cwd,
            firstUserMessage: firstUserContent,
            lastMessageAt: lastTs,
            messageCount: msgCount
        )
    }

    private static func consume(
        line: Data,
        sid: inout String?,
        cwd: inout String?,
        firstUserContent: inout String?,
        lastTs: inout Date?,
        msgCount: inout Int,
        formatter: ISO8601DateFormatter
    ) {
        if line.isEmpty { return }
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        if sid == nil, let s = json["sessionId"] as? String { sid = s }
        if cwd == nil, let c = json["cwd"] as? String { cwd = c }
        let type = json["type"] as? String
        if type == "user" || type == "assistant" {
            msgCount += 1
            if let ts = json["timestamp"] as? String, let d = formatter.date(from: ts) {
                lastTs = d
            }
        }
        if firstUserContent == nil, type == "user",
           let msg = json["message"] as? [String: Any] {
            // Content can be a string (early format) or an array of content blocks
            // (current format). Take the first text we find.
            if let s = msg["content"] as? String {
                firstUserContent = String(s.prefix(140))
            } else if let arr = msg["content"] as? [[String: Any]] {
                for block in arr {
                    if let text = block["text"] as? String {
                        firstUserContent = String(text.prefix(140))
                        break
                    }
                }
            }
        }
    }
}
