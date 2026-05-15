import Foundation

// Immutable description of how to spawn the process for a Task. Does NOT
// carry runtime state (no pid, no exit code, no aliveness) — those live
// on Task.runtime and are reconciled against the agent on disk. The spec
// is set once at Task creation and re-used for every restart of that
// Task's agent.
public struct ProcessSpec: Codable, Equatable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var cwd: URL
    // Bytes typed into the spawned PTY's master after the child renders its
    // first prompt. Used for the "spawn zsh, then type `claude\n`" flow that
    // mimics the user's manual claude invocation — claude only reflows on
    // SIGWINCH when started this way. See ClaudeTaskSpec for the rationale.
    public var initialInput: String?

    public init(
        command: String,
        args: [String],
        env: [String: String],
        cwd: URL,
        initialInput: String?
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.initialInput = initialInput
    }

    private enum CodingKeys: String, CodingKey {
        case command, args, env, cwd, initialInput
    }

    // Legacy fields `pid` and `restartPolicy` are silently ignored on
    // decode — they're not part of the current spec but may appear in
    // snapshots written by older Mani builds.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.command = try c.decode(String.self, forKey: .command)
        self.args = try c.decode([String].self, forKey: .args)
        self.env = try c.decode([String: String].self, forKey: .env)
        self.cwd = try c.decode(URL.self, forKey: .cwd)
        self.initialInput = try c.decodeIfPresent(String.self, forKey: .initialInput)
    }
}
