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
            snapshotIntervalSeconds: 30
        )
    )
}

public struct Settings: Codable, Equatable {
    public var scrollbackCapBytes: Int
    public var snapshotIntervalSeconds: Int

    public init(scrollbackCapBytes: Int, snapshotIntervalSeconds: Int) {
        self.scrollbackCapBytes = scrollbackCapBytes
        self.snapshotIntervalSeconds = snapshotIntervalSeconds
    }
}
