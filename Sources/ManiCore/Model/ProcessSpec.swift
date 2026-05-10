import Foundation

public struct ProcessSpec: Codable, Equatable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var cwd: URL
    public var pid: Int32?
    // Bytes typed into the spawned PTY's master after the child renders its
    // first prompt. Used for the "spawn zsh, then type `claude\n`" flow that
    // mimics the user's manual claude invocation — see EffectRunner.
    public var initialInput: String?

    public init(
        command: String,
        args: [String],
        env: [String: String],
        cwd: URL,
        pid: Int32?,
        initialInput: String?
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.pid = pid
        self.initialInput = initialInput
    }

    private enum CodingKeys: String, CodingKey {
        case command, args, env, cwd, pid, initialInput
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.command = try c.decode(String.self, forKey: .command)
        self.args = try c.decode([String].self, forKey: .args)
        self.env = try c.decode([String: String].self, forKey: .env)
        self.cwd = try c.decode(URL.self, forKey: .cwd)
        self.pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        self.initialInput = try c.decodeIfPresent(String.self, forKey: .initialInput)
    }
}
