import Foundation
import Darwin

// Abstract surface for a running task's I/O. ManagedPTY (Mani-spawned,
// in-process forkpty + master FD) and AgentClient (talking to a
// detached mani-agent via UNIX socket) both conform. Lets the
// renderer + EffectRunner be agnostic about WHERE the bytes come
// from.
//
// The shape mirrors the original ManagedPTY public surface: input
// goes one way, output is multi-subscriber, resize is an out-of-
// band call, exit is an onExit closure. Same semantics either way.
protocol TaskIO: AnyObject {
    // PID of the inner process. For ManagedPTY this is the forkpty
    // child; for AgentClient it's read from the EXIT frame or set
    // by the host when known.
    var pid: pid_t { get }
    // Fires with the exit code when the inner process dies.
    var onExit: ((Int32) -> Void)? { get set }
    // Send bytes to the inner process's stdin (PTY master write).
    func write(_ data: Data)
    // Notify the inner process of a new terminal size (TIOCSWINSZ
    // or a RESIZE frame over the wire).
    func resize(rows: UInt16, cols: UInt16)
    // Multi-subscriber output stream. The returned token's deinit
    // unhooks the handler — same RAII pattern as the original
    // ManagedPTY.OutputSubscription.
    func addOutputHandler(_ handler: @escaping (Data) -> Void) -> IOSubscription
    // `replayCaptured: false` means: don't replay buffered bytes to
    // this handler. Used when re-attaching a renderer whose surface
    // already contains the older bytes (cached renderer flow).
    func addOutputHandler(replayCaptured: Bool, _ handler: @escaping (Data) -> Void) -> IOSubscription
    // Prepend `data` to the internal capture buffer so a subsequent
    // addOutputHandler(replayCaptured: true) sees `data` first, then
    // any live bytes that accumulated since the impl came up. Used
    // at boot reconciliation to feed the on-disk scrollback tail
    // into the same replay path live bytes use — the renderer is
    // byte-indifferent. Cap-trims if seed + existing live exceed
    // the impl's internal capture cap; seed wins, oldest live bytes
    // are dropped. Must be called before any handler subscribes.
    func seedCapturedOutput(_ data: Data)
}

// Subscription token returned by addOutputHandler. On deinit, the
// associated handler is unhooked from the underlying source.
final class IOSubscription {
    private let cancel: () -> Void
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}
