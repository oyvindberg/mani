import Foundation

// "Job" is the internal type name for what we call a "task" in the UI and in
// conversation. Renamed to avoid endless ambiguity with Swift's _Concurrency.Task.
public struct Job: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var kind: JobKind
    public var enabled: Bool
    public var status: JobStatus
    public var primary: ProcessSpec
    public var auxiliary: [ProcessSpec]
    public var unread: Int
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: UUID,
        name: String,
        kind: JobKind,
        enabled: Bool,
        status: JobStatus,
        primary: ProcessSpec,
        auxiliary: [ProcessSpec],
        unread: Int,
        createdAt: Date,
        completedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.status = status
        self.primary = primary
        self.auxiliary = auxiliary
        self.unread = unread
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

public enum JobKind: Codable, Equatable {
    case claude(sessionId: String?)
    case shell
    case custom(label: String)
}

public enum JobStatus: String, Codable, Equatable {
    case running
    case idle
    case stopped
    case completed
    case failed
}
