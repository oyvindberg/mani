import Foundation
import ManiServer

// TaskIO adapter for remote mode. The renderer code path is unchanged —
// it calls addOutputHandler / write / resize on a TaskIO, and this
// class translates each call into the corresponding v0.2 wire frame
// (subscribeTaskOutput / taskInput / taskResize) over the WS to the
// mani-server.
//
// Threading: addOutputHandler returns immediately and spawns a Task to
// consume the AsyncStream from the WS client. Each yielded byte chunk
// is forwarded to the handler on the main queue (matching what
// AgentClient does via scheduleReplay — keeps libghostty's feed
// semantics consistent).
final class RemoteTaskIO: TaskIO {
    let taskId: UUID
    let pid: Int32 = 0
    var onExit: ((Int32) -> Void)?

    private weak var client: RemoteWSClient?

    init(taskId: UUID, client: RemoteWSClient) {
        self.taskId = taskId
        self.client = client
    }

    func write(_ data: Data) {
        guard let client else { return }
        _Concurrency.Task { await client.sendTaskInput(taskId: taskId, data: data) }
    }

    func resize(rows: UInt16, cols: UInt16) {
        guard let client else { return }
        _Concurrency.Task { await client.sendTaskResize(taskId: taskId, cols: cols, rows: rows) }
    }

    func addOutputHandler(_ handler: @escaping (Data) -> Void) -> IOSubscription {
        addOutputHandler(replayCaptured: true, handler)
    }

    func addOutputHandler(replayCaptured: Bool, _ handler: @escaping (Data) -> Void) -> IOSubscription {
        // The server-side subscribeTaskOutput honors replayCaptured by
        // default — its handler does addOutputHandler(replayCaptured:
        // true) when the WS client subscribes. So this flag is
        // currently advisory on the client side; the wire doesn't
        // carry it. Hook to add later if needed.
        guard let client else {
            return IOSubscription { }
        }
        let id = taskId
        // RemoteWSClient is MainActor-isolated; hop to it to subscribe,
        // then iterate the AsyncStream inline on main and feed handler.
        let task = _Concurrency.Task { @MainActor in
            let stream = client.subscribeTaskOutput(taskId: id)
            for await data in stream {
                handler(data)
            }
        }
        return IOSubscription { task.cancel() }
    }

    // No client-side captured buffer to seed in remote mode — the
    // server runs the scrollback-seed-on-attach path itself and
    // delivers those bytes through subscribeTaskOutput's reply.
    func seedCapturedOutput(_ data: Data) { }
}
