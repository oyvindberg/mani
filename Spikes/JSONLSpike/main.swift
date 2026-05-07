import Foundation

// JSONLSpike: streams Claude Code session JSONL files, extracting the
// fields we need for v0.1's watcher (session_id, last_message_at,
// message_count, token usage). Reports which fields are present and
// which are missing or malformed across the input set, so we can pick
// degradation rules (e.g. "if `usage` missing, show `?`").

struct SessionSummary {
    var path: String
    var lineCount: Int = 0
    var parseFailures: Int = 0
    var typeCounts: [String: Int] = [:]
    var sessionId: String?
    var firstTimestamp: String?
    var lastTimestamp: String?
    var userMessages: Int = 0
    var assistantMessages: Int = 0
    var totalInputTokens: Int = 0
    var totalCacheCreationTokens: Int = 0
    var totalCacheReadTokens: Int = 0
    var totalOutputTokens: Int = 0
    var assistantWithUsage: Int = 0
    var assistantWithoutUsage: Int = 0
    var modelsSeen: Set<String> = []
    var topLevelKeysSeen: Set<String> = []
    var assistantMessageKeysSeen: Set<String> = []
    var usageKeysSeen: Set<String> = []
}

func processFile(at path: String) -> SessionSummary {
    var s = SessionSummary(path: path)

    guard let stream = InputStream(fileAtPath: path) else { return s }
    stream.open()
    defer { stream.close() }

    var partial = Data()
    var buf = [UInt8](repeating: 0, count: 65536)

    while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        partial.append(buf, count: n)

        while let nl = partial.firstIndex(of: 0x0A) {
            let line = partial.subdata(in: 0..<nl)
            partial.removeSubrange(0...nl)
            consume(line: line, into: &s)
        }
    }
    if !partial.isEmpty {
        consume(line: partial, into: &s)
    }
    return s
}

func consume(line: Data, into s: inout SessionSummary) {
    if line.isEmpty { return }
    s.lineCount += 1
    guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
        s.parseFailures += 1
        return
    }

    for (k, _) in obj { s.topLevelKeysSeen.insert(k) }

    let type = (obj["type"] as? String) ?? "(none)"
    s.typeCounts[type, default: 0] += 1

    if let sid = obj["sessionId"] as? String, s.sessionId == nil {
        s.sessionId = sid
    }
    if let ts = obj["timestamp"] as? String {
        if s.firstTimestamp == nil { s.firstTimestamp = ts }
        s.lastTimestamp = ts
    }

    switch type {
    case "user":
        s.userMessages += 1
    case "assistant":
        s.assistantMessages += 1
        if let msg = obj["message"] as? [String: Any] {
            for (k, _) in msg { s.assistantMessageKeysSeen.insert(k) }
            if let model = msg["model"] as? String { s.modelsSeen.insert(model) }
            if let usage = msg["usage"] as? [String: Any] {
                s.assistantWithUsage += 1
                for (k, _) in usage { s.usageKeysSeen.insert(k) }
                s.totalInputTokens += (usage["input_tokens"] as? Int) ?? 0
                s.totalCacheCreationTokens += (usage["cache_creation_input_tokens"] as? Int) ?? 0
                s.totalCacheReadTokens += (usage["cache_read_input_tokens"] as? Int) ?? 0
                s.totalOutputTokens += (usage["output_tokens"] as? Int) ?? 0
            } else {
                s.assistantWithoutUsage += 1
            }
        }
    default:
        break
    }
}

func report(_ s: SessionSummary) {
    let name = (s.path as NSString).lastPathComponent
    print("─── \(name)")
    print("  lines:           \(s.lineCount) (parse failures: \(s.parseFailures))")
    print("  session_id:      \(s.sessionId ?? "(missing)")")
    print("  timestamps:      \(s.firstTimestamp ?? "?")  →  \(s.lastTimestamp ?? "?")")
    print("  user/assistant:  \(s.userMessages) / \(s.assistantMessages)")
    print("  with-usage:      \(s.assistantWithUsage) / without-usage: \(s.assistantWithoutUsage)")
    let total = s.totalInputTokens + s.totalCacheCreationTokens + s.totalCacheReadTokens + s.totalOutputTokens
    print("  tokens (in/cc/cr/out): \(s.totalInputTokens) / \(s.totalCacheCreationTokens) / \(s.totalCacheReadTokens) / \(s.totalOutputTokens) (sum=\(total))")
    print("  models:          \(s.modelsSeen.sorted().joined(separator: ", "))")
    let typesSorted = s.typeCounts.sorted { $0.value > $1.value }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ", ")
    print("  line types:      \(typesSorted)")
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    let bin = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "JSONLSpike"
    print("Usage: \(bin) <jsonl-path> [<jsonl-path> ...]")
    exit(2)
}

var allSummaries: [SessionSummary] = []
let totalStart = Date()
for path in args {
    let summary = processFile(at: path)
    report(summary)
    allSummaries.append(summary)
}
let elapsed = Date().timeIntervalSince(totalStart)

print("")
print("─── Aggregate")
print("  files:           \(allSummaries.count)")
print("  total lines:     \(allSummaries.reduce(0) { $0 + $1.lineCount })")
print("  parse failures:  \(allSummaries.reduce(0) { $0 + $1.parseFailures })")
print("  elapsed:         \(String(format: "%.2f", elapsed))s")

// Union of all top-level / assistant message / usage keys.
let allTopLevel = allSummaries.flatMap { $0.topLevelKeysSeen }.sorted().reduce(into: Set<String>()) { $0.insert($1) }.sorted()
let allAssistantKeys = allSummaries.flatMap { $0.assistantMessageKeysSeen }.sorted().reduce(into: Set<String>()) { $0.insert($1) }.sorted()
let allUsageKeys = allSummaries.flatMap { $0.usageKeysSeen }.sorted().reduce(into: Set<String>()) { $0.insert($1) }.sorted()
print("")
print("─── Union schema (across all files)")
print("  top-level keys:        \(allTopLevel.joined(separator: ", "))")
print("  assistant.message keys: \(allAssistantKeys.joined(separator: ", "))")
print("  assistant.message.usage keys: \(allUsageKeys.joined(separator: ", "))")
