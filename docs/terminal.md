# Terminal

Two halves: the **PTY** (we own this) and the **renderer** (swappable). The
seam goes between them. Anything that depends on a specific renderer
(SwiftTerm vs libghostty) must live behind the renderer protocol.

## ManagedPTY

```swift
final class ManagedPTY {
    let spec: ProcessSpec
    private(set) var pid: pid_t?
    private let masterFD: Int32
    private let outputContinuation: AsyncStream<Data>.Continuation
    let output: AsyncStream<Data>           // raw bytes from child

    init(spec: ProcessSpec) throws { … }

    func write(_ data: Data)                // user keystrokes → child
    func resize(rows: Int, cols: Int)       // ioctl TIOCSWINSZ
    func terminate(escalateAfter: TimeInterval) async
}
```

Responsibilities:
- Open a master/slave PTY pair (`openpty()` / `posix_openpt()`).
- `posix_spawn` the child with the slave as its stdin/stdout/stderr.
- Track the child PID; reap on exit.
- Tee output to two consumers: the renderer (live display) and the
  scrollback writer (Tier 1 persistence — see `persistence.md`).
- Handle SIGCHLD to detect child exit; turn into a `processExited` action
  via the EffectRunner.
- Resize the PTY when the renderer's font/size changes.
- Terminate gracefully: SIGTERM, then SIGKILL after `escalateAfter` seconds.

**Output ownership.** The PTY's `output` stream is consumed by *both* the
scrollback writer and the renderer. The scrollback writer is the source of
truth — restoring a task means re-feeding the scrollback log into the new
renderer, capped to its display buffer. Don't ask the renderer to "save
its scrollback" — its in-memory buffer is for display only.

**Thread/actor safety.** `ManagedPTY` is an `actor` or runs on a dedicated
serial dispatch queue. Concurrent writes from UI keystrokes (the renderer)
and supervisor messages must serialize.

## TerminalRenderer protocol

```swift
@MainActor
protocol TerminalRenderer {
    associatedtype Body: View
    init(pty: ManagedPTY)
    var view: Body { get }
    func resize(rows: Int, cols: Int)
    func setTheme(_ theme: TerminalTheme)
    func search(_ query: String) -> [SearchHit]   // optional capability; return [] if unsupported
    func selectionAsString() -> String?
    func scrollToBottom()
}
```

Why this shape:
- `init(pty:)` — the renderer subscribes to `pty.output` and sends keystrokes
  via `pty.write`. The renderer doesn't *own* the PTY; it observes and
  controls it.
- `view: Body` — SwiftUI view to embed in a tab. Renderer-specific impls
  return their own `View` type via the associated type.
- `resize` — forwarded from the window's geometry. Renderer computes
  rows/cols from font metrics and forwards to the PTY.
- Capability methods (search, etc.) return empty/`false` when unsupported,
  rather than `throws` or `Optional<Method>`. Capability negotiation is
  call-site-cheap.

```swift
@MainActor
struct AnyTerminalRenderer {
    let view: AnyView
    let resize: (Int, Int) -> Void
    let setTheme: (TerminalTheme) -> Void
    // …
}
```

Type-erased wrapper for storage in models that don't know which concrete
renderer is used.

## SwiftTerm — the v0.1 choice

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza
is pure Swift, drops into AppKit/SwiftUI as an `NSView`, no FFI, no Zig
toolchain. Drawbacks: software-rendered, lower performance ceiling than
GPU-accelerated terminals.

For Claude Code workloads (mostly text, occasional bursts), it's adequate.
**Spike 1 in `docs/spikes.md` validates this.**

### SwiftTerm adapter sketch

```swift
import SwiftTerm

@MainActor
final class SwiftTermRenderer: TerminalRenderer {
    let pty: ManagedPTY
    private let host: SwiftTermHost                // wraps SwiftTerm.TerminalView

    init(pty: ManagedPTY) {
        self.pty = pty
        self.host = SwiftTermHost(
            onUserInput: { data in pty.write(data) },
            onResize: { rows, cols in pty.resize(rows: rows, cols: cols) }
        )
        Task {
            for await chunk in pty.output {
                await MainActor.run { host.feed(chunk) }
            }
        }
    }

    var view: some View { TerminalViewRepresentable(host: host) }

    func resize(rows: Int, cols: Int) {
        host.resize(rows: rows, cols: cols)
    }

    func setTheme(_ theme: TerminalTheme) {
        host.setColors(theme.toSwiftTermColors())
    }

    func search(_ query: String) -> [SearchHit] {
        host.search(query)
    }

    func selectionAsString() -> String? { host.selection }
    func scrollToBottom() { host.scrollToBottom() }
}
```

Where `SwiftTermHost` is a thin wrapper that hides SwiftTerm's
`TerminalView` and `LocalProcessTerminalViewDelegate` underneath
SwiftTerm-specific colors/types so they don't leak into our model layer.

### SwiftTerm install

When you start spike 1 (and only then):

```swift
// Package.swift — only after spike 1 is green and you're moving from spike to v0.1
dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
],
targets: [
    .target(
        name: "ManiApp",
        dependencies: ["ManiCore", "SwiftTerm"]
    ),
    // ManiCore stays Foundation-only — no SwiftTerm dep there.
]
```

Note: `ManiApp` does not yet exist. It'll be added when the Xcode app
target is set up. Until then, SwiftTerm has no place in the package.

## libghostty — the v0.2+ option

Mitchell Hashimoto has been factoring [Ghostty](https://github.com/ghostty-org/ghostty)'s
core into `libghostty`, a C API wrapping the parser/grid/renderer. The
macOS app is a SwiftUI shell calling into it.

Why it's interesting later:
- GPU-accelerated rendering. Higher performance ceiling.
- Same Swift+C bridge pattern as Ghostty's reference embedding.

Why not v0.1:
- libghostty's public API is **not yet stable**. Pinning to a commit is
  feasible; expect rebase work each release.
- Build dependency on Zig toolchain.
- Embedding story still being shaped. The macOS app is the reference; we'd
  fork/borrow from there.

The protocol seam (`TerminalRenderer`) keeps the swap clean. Implement
`GhosttyRenderer: TerminalRenderer` later, gate on a setting, ship.

## Scrollback restoration

When recovering a task whose scrollback log exists on disk:

1. Spawn the new PTY (process re-launch via safelist).
2. Create the new renderer.
3. **Before** wiring the PTY's live output to the renderer, feed the
   tail of `tasks/<id>/scrollback.log` to the renderer (capped to the
   renderer's display buffer — typically the last few thousand lines).
4. Then wire live output.

This gives the user the impression that they "still have" their previous
session in scroll, even though the actual process is new.

## Resize protocol

User resizes the window → SwiftUI updates the renderer view's geometry →
renderer computes new rows/cols from its font metrics → renderer calls:

```swift
self.pty.resize(rows: newRows, cols: newCols)
self.host.resize(rows: newRows, cols: newCols)
```

In that order. The PTY's `ioctl(TIOCSWINSZ)` triggers `SIGWINCH` in the
child, so terminal apps (vim, less, etc.) can re-layout. The renderer
re-grids before next paint.

Don't try to compute rows/cols at the model layer. It depends on font
metrics and pixel sizes, which only the renderer knows.

## Capabilities by renderer

| Capability | SwiftTerm | libghostty (later) |
|------------|-----------|--------------------|
| ANSI colors | ✓ | ✓ |
| 256-color and truecolor | ✓ | ✓ |
| Mouse | ✓ | ✓ |
| Hyperlinks (OSC 8) | partial | ✓ |
| Sixel | ✗ | ✓ |
| Kitty graphics | ✗ | ✓ |
| Search | via wrapper | ✓ |

For v0.1 we accept SwiftTerm's capability set. If a user complains about
e.g. Sixel, that's a v0.2 driver for the libghostty swap.

## Sharp edges to watch for

1. **PTY zombies.** If the child exits but no one waits for it, you get
   a zombie. The PTY layer must `waitpid` (or equivalent via `Process`)
   inside SIGCHLD handling.
2. **`postSpawn` window.** Between `posix_spawn` returning and the child
   `exec`'ing, the child's PID exists but there's nothing to send signals
   to yet. If `terminate` is called in this window, retry with a small
   backoff.
3. **OSC 7 (cwd reporting).** Most modern shells emit OSC 7 sequences
   reporting their cwd as the user `cd`s. This is how we know where the
   user is for snapshot purposes. SwiftTerm parses it; pull it via the
   delegate. If the user uses an old shell that doesn't emit OSC 7,
   we fall back to the spawn cwd.
4. **OSC 133 (prompt boundaries).** Useful for "command finished" detection
   without OS-level ptrace. Modern starship/zsh/bash setups emit it.
   Optional for v0.1.
5. **Terminal type.** Set `TERM=xterm-256color` in spawn env unless the
   user overrides. SwiftTerm advertises this.
6. **Locale.** Set `LANG`/`LC_ALL` to UTF-8 (`en_US.UTF-8` or user's
   default) so emoji and non-ASCII render correctly.

## When you start spike 1

Order of operations:

1. **Don't** add SwiftTerm to `Package.swift` yet. The package stays
   library-only (`ManiCore`).
2. Open `Package.swift` in Xcode (File → Open → pick the directory).
3. From Xcode: File → New → Project → macOS → App → SwiftUI → put it in
   `~/pr/mani/App/` (it creates an `Mani.xcodeproj`).
4. In the new app target's Package Dependencies: add the local package
   (`~/pr/mani`) — depends on `ManiCore`. Add SwiftTerm
   (`https://github.com/migueldeicaza/SwiftTerm`).
5. Write the spike: a single window with one shell PTY rendered through
   SwiftTerm. Don't bother wiring `ManagedPTY` yet — use SwiftTerm's
   `LocalProcessTerminalView` for the spike to validate rendering only.
6. Torture-test as in `docs/spikes.md` § Spike 1.
7. **If green:** delete the spike's `LocalProcessTerminalView` usage,
   build the real `ManagedPTY` + `SwiftTermRenderer` per this doc, wire
   to the model. That's spike 2 territory.
8. **If red:** stop and surface to the user. Decision tree:
   - Performance bad on idle: try GPU layer / Metal-backed view if SwiftTerm
     supports it.
   - Performance bad on bursts: investigate input throttling.
   - Specific glitch (rendering, input): file an issue with SwiftTerm,
     consider libghostty earlier than planned.
