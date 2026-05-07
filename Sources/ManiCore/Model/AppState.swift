import Foundation

public struct AppState: Codable, Equatable {
    public var schemaVersion: Int
    public var projects: [Project]
    public var settings: Settings

    public init(schemaVersion: Int, projects: [Project], settings: Settings) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.settings = settings
    }

    public static let empty = AppState(
        schemaVersion: 1,
        projects: [],
        settings: Settings(
            scrollbackCapBytes: 32 * 1024 * 1024,
            snapshotIntervalSeconds: 30,
            terminalTheme: "Dracula"
        )
    )
}

public struct Settings: Codable, Equatable {
    public var scrollbackCapBytes: Int
    public var snapshotIntervalSeconds: Int
    // Name of a Ghostty theme from the GhosttyTheme catalog, e.g. "Dracula",
    // "Tokyo Night Storm", "GitHub Light". Looked up at terminal-pane mount
    // time; changing requires re-mounting the affected pane.
    public var terminalTheme: String

    public init(
        scrollbackCapBytes: Int,
        snapshotIntervalSeconds: Int,
        terminalTheme: String
    ) {
        self.scrollbackCapBytes = scrollbackCapBytes
        self.snapshotIntervalSeconds = snapshotIntervalSeconds
        self.terminalTheme = terminalTheme
    }

    // Backward-compat decode: state.json files written before terminalTheme
    // existed don't have that key. decodeIfPresent supplies the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scrollbackCapBytes = try c.decode(Int.self, forKey: .scrollbackCapBytes)
        self.snapshotIntervalSeconds = try c.decode(Int.self, forKey: .snapshotIntervalSeconds)
        self.terminalTheme = (try? c.decodeIfPresent(String.self, forKey: .terminalTheme)) ?? "Dracula"
    }
}
