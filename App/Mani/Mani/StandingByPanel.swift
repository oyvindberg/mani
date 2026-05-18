import SwiftUI
import AppKit
import Combine
import ManiCore

// NSPanel host + view model + global hotkey wiring for the
// "Standing by." overlay. The SwiftUI view itself lives in
// StandingByView.swift; this file owns lifecycle, focus, and the
// pure transform from AppState/Tracker → display entries.

// MARK: - View model

@MainActor
final class StandingByViewModel: ObservableObject {
    @Published var entries: [StandingByEntry] = []
    @Published var focusedEntryId: String?

    func focusNext() {
        guard !entries.isEmpty else { return }
        guard let current = focusedEntryId,
              let idx = entries.firstIndex(where: { $0.id == current })
        else {
            focusedEntryId = entries.first?.id
            return
        }
        let next = (idx + 1) % entries.count
        focusedEntryId = entries[next].id
    }

    func focusPrevious() {
        guard !entries.isEmpty else { return }
        guard let current = focusedEntryId,
              let idx = entries.firstIndex(where: { $0.id == current })
        else {
            focusedEntryId = entries.last?.id
            return
        }
        let prev = (idx - 1 + entries.count) % entries.count
        focusedEntryId = entries[prev].id
    }
}

// MARK: - Panel

final class StandingByPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

@MainActor
final class StandingByPanelController: NSObject {
    static let shared = StandingByPanelController()

    private let viewModel = StandingByViewModel()
    private var panel: StandingByPanel?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private weak var store: Store?
    private weak var tracker: TaskActivityTracker?
    private var globalHotkey: GlobalHotkey?
    private var appLocalToggleMonitor: Any?
    private var trackerSink: AnyCancellable?

    func configure(store: Store, tracker: TaskActivityTracker) {
        self.store = store
        self.tracker = tracker
        if globalHotkey == nil {
            globalHotkey = GlobalHotkey(
                keyCode: HotkeyKey.m,
                modifiers: HotkeyModifiers([.command, .shift]).rawValue,
                onPress: { [weak self] in
                    self?.toggle()
                }
            )
        }
        if appLocalToggleMonitor == nil {
            appLocalToggleMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                if event.window === self.panel { return event }
                let target = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                guard target == [.command, .shift] else { return event }
                guard event.charactersIgnoringModifiers?.lowercased() == "m"
                else { return event }
                self.toggle()
                return nil
            }
        }
    }

    func toggle() {
        if let panel, panel.isVisible {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        if !rebuildEntries() {
            populateForDebug()
        }

        let panel = panel ?? makePanel()
        self.panel = panel

        let host = NSHostingController(rootView: StandingByHostView(
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        host.view.translatesAutoresizingMaskIntoConstraints = true
        panel.contentViewController = host

        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        panel.setContentSize(size)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - size.width / 2
            let y = frame.minY + frame.height * 0.62 - size.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        installKeyMonitor()
        installClickOutsideMonitor()
        installLiveDataSubscription()
    }

    func dismiss() {
        removeMonitors()
        trackerSink = nil

        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func removeKeyMonitor() {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }

        switch event.keyCode {
        case 53:   // esc
            dismiss()
            return nil
        case 125:  // down arrow
            viewModel.focusNext()
            return nil
        case 126:  // up arrow
            viewModel.focusPrevious()
            return nil
        case 36, 76:  // return, numpad enter
            if event.modifierFlags.contains(.option) {
                activateFocusedEntry(dismissPanel: false)
            } else {
                activateFocusedEntry(dismissPanel: true)
            }
            return nil
        default:
            if let chars = event.charactersIgnoringModifiers,
               let digit = chars.first?.wholeNumberValue,
               digit >= 1, digit <= 9 {
                let idx = digit - 1
                if idx < viewModel.entries.count {
                    viewModel.focusedEntryId = viewModel.entries[idx].id
                    return nil
                }
            }
            return event
        }
    }

    // MARK: - Click outside dismiss

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }

    private func removeMonitors() {
        removeKeyMonitor()
        removeClickOutsideMonitor()
    }

    // MARK: - Enter activation

    private func activateFocusedEntry(dismissPanel: Bool) {
        guard let id = viewModel.focusedEntryId,
              let entry = viewModel.entries.first(where: { $0.id == id }),
              let store
        else { return }
        guard let path = resolveTaskPath(sessionId: entry.id, in: store.state)
        else { return }
        if dismissPanel { dismiss() }
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainAppWindow() {
            window.makeKeyAndOrderFront(nil)
        }
        _Concurrency.Task { @MainActor in
            await store.dispatch(.selectTask(at: path))
        }
    }

    private func resolveTaskPath(sessionId: String, in state: AppState) -> TaskPath? {
        for repo in state.repos {
            for project in repo.projects {
                for task in project.tasks {
                    if case let .claude(sid) = task.kind, sid == sessionId {
                        return TaskPath(
                            repo: repo.id,
                            project: project.id,
                            task: task.id
                        )
                    }
                }
            }
        }
        return nil
    }

    private func mainAppWindow() -> NSWindow? {
        NSApp.windows.first(where: { window in
            window !== panel && window.canBecomeMain
        })
    }

    // MARK: - Live data

    @discardableResult
    private func rebuildEntries() -> Bool {
        guard let store, let tracker else { return false }
        viewModel.entries = Self.buildEntries(
            state: store.state,
            tracker: tracker
        )
        // Honor existing focus if the row is still in the list,
        // else focus the first row (ready section comes first so
        // that's the most urgent entry).
        if let current = viewModel.focusedEntryId,
           viewModel.entries.contains(where: { $0.id == current }) {
            return true
        }
        viewModel.focusedEntryId = viewModel.entries.first?.id
        return true
    }

    private func installLiveDataSubscription() {
        guard let tracker, let store else { return }
        let setChanges = tracker.$awaitingInputSessions.map { _ in () }
        let timeChanges = tracker.$awaitingInputSince.map { _ in () }
        let thinkingChanges = tracker.$thinkingSessions.map { _ in () }
        let storeChanges = store.objectWillChange.map { _ in () }
        trackerSink = Publishers.Merge4(
            setChanges, timeChanges, thinkingChanges, storeChanges
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.rebuildEntries()
        }
    }

    // Pure transform: walk every claude task in state, classify by
    // status, sort within each section. Output order matches
    // section render order so the navigation cursor moves
    // top-to-bottom through ready → working → idle.
    //
    // Status rules:
    //   ready    = awaitingInput latched OR (unread > 0 && !thinking)
    //   working  = thinking now (regardless of unread / awaiting)
    //   idle     = everything else (a live claude that's quiet)
    //
    // We deliberately include claudes that aren't currently
    // .running too — they just classify as idle. The user might
    // want to see a finished-but-not-yet-restarted task in the
    // list for context; dropping them would silently hide work.
    private static func buildEntries(
        state: AppState,
        tracker: TaskActivityTracker
    ) -> [StandingByEntry] {
        let cache = ExternalSessionInfoCache.shared

        struct Raw {
            let entry: StandingByEntry
            let status: ClaudeStatus
        }

        var raws: [Raw] = []
        for repo in state.repos {
            let repoColor = SwiftUI.Color(hex: repo.color)
            for project in repo.projects {
                for task in project.tasks {
                    guard case let .claude(sid) = task.kind, let sid
                    else { continue }
                    let status = classify(
                        sid: sid, task: task, tracker: tracker
                    )
                    let timestamp = Self.timestamp(
                        for: status, sid: sid, task: task, tracker: tracker
                    )
                    let preview = cache.entries[sid]?.firstUserMessage
                        ?? (task.renamed ? task.name : nil)
                    raws.append(Raw(
                        entry: StandingByEntry(
                            id: sid,
                            taskId: task.id,
                            repoName: repo.name,
                            projectName: project.name,
                            repoColor: repoColor,
                            preview: preview,
                            status: status,
                            timestamp: timestamp
                        ),
                        status: status
                    ))
                }
            }
        }

        // Order: ready → working → idle. Inside each section sort
        // by timestamp — oldest-first for ready (most urgent at
        // top), newest-first for working/idle (recent context
        // wins).
        let ready = raws
            .filter { $0.status == .ready }
            .sorted { $0.entry.timestamp < $1.entry.timestamp }
            .map(\.entry)
        let working = raws
            .filter { $0.status == .working }
            .sorted { $0.entry.timestamp > $1.entry.timestamp }
            .map(\.entry)
        let idle = raws
            .filter { $0.status == .idle }
            .sorted { $0.entry.timestamp > $1.entry.timestamp }
            .map(\.entry)
        return ready + working + idle
    }

    private static func classify(
        sid: String,
        task: Task,
        tracker: TaskActivityTracker
    ) -> ClaudeStatus {
        if tracker.isThinking(sid: sid) { return .working }
        if tracker.isAwaitingInput(sid: sid) { return .ready }
        if task.unread > 0 { return .ready }
        return .idle
    }

    private static func timestamp(
        for status: ClaudeStatus,
        sid: String,
        task: Task,
        tracker: TaskActivityTracker
    ) -> Date {
        switch status {
        case .ready:
            return tracker.awaitingInputSince(sid: sid)
                ?? tracker.settledAt[sid]
                ?? task.createdAt
        case .working:
            // No per-session "started thinking" time available;
            // fall back to the task's last settled timestamp so
            // recently-resumed sessions sort to the top.
            return tracker.settledAt[sid] ?? task.createdAt
        case .idle:
            return tracker.settledAt[sid] ?? task.createdAt
        }
    }

    // MARK: - Panel factory

    private func makePanel() -> StandingByPanel {
        StandingByPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400)
        )
    }

    // MARK: - Debug fixture (used when controller isn't configured)

    private func populateForDebug() {
        let mani = SwiftUI.Color(red: 0.55, green: 0.85, blue: 0.50)
        let dlab = SwiftUI.Color(red: 0.95, green: 0.65, blue: 0.20)
        let typr = SwiftUI.Color(red: 0.65, green: 0.45, blue: 0.90)
        let now = Date()
        viewModel.entries = [
            StandingByEntry(
                id: "sid-1", taskId: UUID(),
                repoName: "mani", projectName: "auth rewrite",
                repoColor: mani,
                preview: "implement the validator and add tests",
                status: .ready,
                timestamp: now.addingTimeInterval(-540)
            ),
            StandingByEntry(
                id: "sid-2", taskId: UUID(),
                repoName: "dlab", projectName: "bleep CI cache",
                repoColor: dlab,
                preview: "investigate why the cache key keeps invalidating",
                status: .ready,
                timestamp: now.addingTimeInterval(-720)
            ),
            StandingByEntry(
                id: "sid-3", taskId: UUID(),
                repoName: "typr", projectName: "refactor tui",
                repoColor: typr,
                preview: "wire the TUI panel into the React tree",
                status: .working,
                timestamp: now.addingTimeInterval(-8)
            ),
            StandingByEntry(
                id: "sid-4", taskId: UUID(),
                repoName: "mani", projectName: "doc helper",
                repoColor: mani,
                preview: "document the new helper in docs/auth.md",
                status: .idle,
                timestamp: now.addingTimeInterval(-7200)
            ),
            StandingByEntry(
                id: "sid-5", taskId: UUID(),
                repoName: "dlab", projectName: "slides deck",
                repoColor: dlab,
                preview: nil,
                status: .idle,
                timestamp: now.addingTimeInterval(-18000)
            ),
        ]
        viewModel.focusedEntryId = viewModel.entries.first?.id
    }
}

// MARK: - SwiftUI host

private struct StandingByHostView: View {
    @ObservedObject var viewModel: StandingByViewModel
    let onDismiss: () -> Void
    @State private var entered: Bool = false

    var body: some View {
        StandingByView(
            entries: viewModel.entries,
            focusedEntryId: Binding(
                get: { viewModel.focusedEntryId },
                set: { viewModel.focusedEntryId = $0 }
            )
        )
        .scaleEffect(entered ? 1.0 : 0.96)
        .opacity(entered ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                entered = true
            }
        }
        .padding(20)
    }
}
