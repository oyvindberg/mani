import Foundation

public struct ProcessSpec: Codable, Equatable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var cwd: URL
    public var pid: Int32?

    public init(
        command: String,
        args: [String],
        env: [String: String],
        cwd: URL,
        pid: Int32?
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.pid = pid
    }
}
