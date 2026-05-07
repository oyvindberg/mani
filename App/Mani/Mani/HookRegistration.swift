import Foundation

// Merges Mani's hook-shim entries into ~/.claude/settings.json without
// clobbering whatever the user already has there. Identifying our entries
// by their command path (which equals shimPath) keeps the merge idempotent —
// register() can be called every launch.
//
// Per docs/claude-integration.md: "the user's existing ~/.claude/settings.json
// may have hooks. Merge, don't overwrite."

enum HookRegistration {

    // The events we register for. Stable list — new claude-code events would
    // need an update here and a release of Mani.
    static let events: [String] = ["SessionStart", "Stop", "SessionEnd", "Notification"]

    static func register(shimPath: String) {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path

        var settings = readSettings(at: settingsPath)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []

            // Strip any existing entries pointing at this same shim path
            // (covers re-runs where shimPath is unchanged, and old runs
            // where the path was different — those won't match and stay).
            entries = entries.compactMap { entry -> [String: Any]? in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return entry }
                let filtered = inner.filter { ($0["command"] as? String) != shimPath }
                if filtered.isEmpty { return nil }
                if filtered.count == inner.count { return entry }
                var copy = entry
                copy["hooks"] = filtered
                return copy
            }

            // Append our fresh entry.
            entries.append([
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": shimPath,
                ]],
            ])
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        writeSettings(settings, at: settingsPath)
    }

    private static func readSettings(at path: String) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func writeSettings(_ settings: [String: Any], at path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        // Atomic-rename via .new + move so a crash mid-write doesn't leave
        // the user's settings.json half-baked.
        let tmp = path + ".mani.new"
        try? data.write(to: URL(fileURLWithPath: tmp))
        _ = rename(tmp, path)
    }
}
