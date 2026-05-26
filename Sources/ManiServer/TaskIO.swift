import Foundation

// Abstract surface for a running task's I/O. Conformed-to by
// AgentClient (mani-agent over Unix socket), ManagedPTY (in-process
// forkpty), and RemoteTaskIO (the v0.2 client-side adapter that
// translates these calls into mani-server WS frames).
//
// The shape mirrors the original ManagedPTY public surface: input
// goes one way, output is multi-subscriber, resize is an out-of-band
// call, exit is an onExit closure. Same semantics in all three impls.
//
// Lives in ManiServer (not App/Mani) so the client-side
// RemoteTaskIO + the v0.2 ServerClient protocol can reference it
// without depending on the mac app target.
public protocol TaskIO: AnyObject {
    // PID of the inner process. For ManagedPTY this is the forkpty
    // child; for AgentClient it's read from the EXIT frame or set
    // by the host when known; for RemoteTaskIO it's 0 (unknown).
    var pid: Int32 { get }
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
    // RemoteTaskIO no-ops this — server-side reattach already feeds
    // scrollback into subscribeTaskOutput's reply stream.
    func seedCapturedOutput(_ data: Data)
}

// Subscription token returned by addOutputHandler. On deinit, the
// associated handler is unhooked from the underlying source.
public final class IOSubscription {
    private let cancel: () -> Void
    public init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}
