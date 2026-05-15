import Foundation

// The long-lived unit of work in a workspace: a shell, a claude session,
// a diff view, etc. The Task is durable; the process backing it is not.
// A Task's `id` doubles as the agent's identity on disk — every helper
// process Mani spawns binds a UNIX socket at
//   ~/Library/Application Support/Mani/agents/<task.id>.sock
// so "is this Task running?" reduces to a stat + connect-probe on that
// path. The kernel PID is the agent's concern; Mani does not store it.
//
// Naming: the type used to be called `Job` to dodge a collision with
// Swift's `_Concurrency.Task`. That collision is real but tolerable —
// our `Task` has no closure-init, so most `Task { … }` call sites
// resolve to the concurrency type without help. Where it doesn't,
// qualify the concurrency call site as `_Concurrency.Task`. See
// CLAUDE.md rule #3.
public struct Task: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var kind: TaskKind
    public var enabled: Bool
    public var spec: ProcessSpec
    public var runtime: TaskRuntime
    public var unread: Int
    public var createdAt: Date
    // True iff the user has explicitly renamed this Task via the UI.
    // Tracked separately so dedupe sweeps never lose a user rename
    // when collapsing duplicates of the same claude session id.
    public var renamed: Bool

    public init(
        id: UUID,
        name: String,
        kind: TaskKind,
        enabled: Bool,
        spec: ProcessSpec,
        runtime: TaskRuntime,
        unread: Int,
        createdAt: Date,
        renamed: Bool
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.spec = spec
        self.runtime = runtime
        self.unread = unread
        self.createdAt = createdAt
        self.renamed = renamed
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, spec, runtime
        case unread, createdAt, renamed
    }

    // Legacy keys read only by the migration path. Kept separate from
    // CodingKeys so Swift can still synthesize `encode(to:)` against
    // only the current fields.
    private enum LegacyKeys: String, CodingKey {
        case status, primary, completedAt
    }

    // Custom decode supports two on-disk shapes:
    //   - new: { id, name, kind, enabled, spec, runtime, unread, createdAt, renamed }
    //   - old: { id, name, kind, enabled, status, primary, auxiliary, unread,
    //           createdAt, completedAt, renamed }
    // The old shape is mapped: primary → spec, status + completedAt → runtime.
    // auxiliary is dropped. The decoder is forgiving so a snapshot written
    // by an older Mani build still loads cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id          = try c.decode(UUID.self,     forKey: .id)
        self.name        = try c.decode(String.self,   forKey: .name)
        self.kind        = try c.decode(TaskKind.self, forKey: .kind)
        self.enabled     = try c.decode(Bool.self,     forKey: .enabled)
        self.unread      = try c.decode(Int.self,      forKey: .unread)
        self.createdAt   = try c.decode(Date.self,     forKey: .createdAt)
        self.renamed     = (try? c.decodeIfPresent(Bool.self, forKey: .renamed)) ?? false

        if let spec = try c.decodeIfPresent(ProcessSpec.self, forKey: .spec) {
            self.spec = spec
            self.runtime = (try? c.decodeIfPresent(TaskRuntime.self, forKey: .runtime))
                ?? .neverStarted
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            self.spec = try legacy.decode(ProcessSpec.self, forKey: .primary)
            let oldStatus = (try? legacy.decodeIfPresent(String.self, forKey: .status)) ?? "stopped"
            let completedAt = try? legacy.decodeIfPresent(Date.self, forKey: .completedAt)
            if let completedAt {
                self.runtime = .completed(at: completedAt)
            } else if oldStatus == "running" {
                // We can't reconstruct the exact spawn time; createdAt is a
                // safe placeholder, and boot reconciliation will overwrite
                // with .exited if the agent is no longer alive.
                self.runtime = .running(spawnedAt: self.createdAt)
            } else {
                // .stopped / .failed / .idle / unknown — the task had a
                // process at some point but it isn't running now. .exited
                // (vs .neverStarted) gives the UI a "Restart" affordance
                // and the honest "exited" headline, which matches what
                // the user actually experienced.
                self.runtime = .exited(at: self.createdAt, code: -1)
            }
        }
    }
}

public enum TaskKind: Codable, Equatable {
    case claude(sessionId: String?)
    case shell
    case diff
    case custom(label: String)
}

// What we believe the Task's process is currently doing. This is reducer-
// owned state — but the kernel can kill a process at any time without
// telling us, so any code that ATTACHES to a `.running` Task must be
// prepared to discover the agent is gone (socket missing, connect refused,
// EOF on first read) and dispatch `.taskExited` to reconcile. Boot
// reconciliation does the same sweep for every `.running` Task in state.
public enum TaskRuntime: Codable, Equatable {
    // Created but the spawn effect has not been issued yet, or this is
    // an externally-discovered claude task whose process we don't own.
    case neverStarted
    // We believe an agent for this task.id is currently alive.
    case running(spawnedAt: Date)
    // The agent has exited (gracefully, crashed, or was killed). `code`
    // is the inner process's exit code if known, or -1 if the agent
    // vanished without reporting one.
    case exited(at: Date, code: Int32)
    // User explicitly marked the task as done. Won't auto-restart.
    case completed(at: Date)
}
