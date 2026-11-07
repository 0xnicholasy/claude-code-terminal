import AppKit
import CCProtocol
import Foundation
import GhosttyTerminal

/// One terminal pane. It records whether a process has been launched (`launched`) but spawns
/// nothing itself: the terminal view state, which owns the pty, is created only when a view asks.
@MainActor
final class Pane: ObservableObject, Identifiable {
    enum Origin { case new, resume }

    nonisolated let id: String
    let cwd: String
    @Published var title: String
    var origin: Origin
    private(set) var launched: LaunchSpec?
    private var terminal: TerminalViewState?
    var onChange: (() -> Void)?

    init(sessionId: String, cwd: String, title: String, origin: Origin) {
        id = sessionId
        self.cwd = cwd
        self.title = title
        self.origin = origin
    }

    var hasProcess: Bool { launched != nil }

    func markLaunched(_ spec: LaunchSpec) {
        launched = spec
        origin = .resume
    }

    func markExited() {
        launched = nil
        terminal = nil
        onChange?()
    }

    /// One libghostty controller (config + app instance) shared by every pane. Ghostty's default
    /// `super+q=quit` keybind makes a focused surface swallow Cmd-Q, and this host does not handle
    /// the quit action, so Cmd-Q never reached the app menu (seen live 2026-11-07). Unbind it so
    /// the standard Quit menu item handles it.
    static let sharedController = TerminalController { $0.withCustom("keybind", "super+q=unbind") }

    /// Creates the libghostty surface state on first use. Only called from a view for a launched pane.
    func viewState() -> TerminalViewState? {
        guard let spec = launched else { return nil }
        if let terminal { return terminal }
        let state = TerminalViewState(controller: Pane.sharedController)
        state.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: spec.cwd,
            command: spec.ghosttyCommand
        )
        state.onClose = { [weak self] _ in
            Task { @MainActor in self?.markExited() }
        }
        terminal = state
        return state
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var panes: [Pane] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var sessions: [SessionInfo] = []
    @Published var notice: String?
    /// True while sessions come from the ccgovd socket; false while polling `claude agents --json`.
    @Published var daemonConnected = false
    @Published private(set) var freed = FreedTracker()

    var windowFrame: LayoutFrame? {
        didSet { if windowFrame != oldValue { persist() } }
    }

    private let store: LayoutStore?
    private let claudePath: @Sendable () -> String?
    /// Tells ccgovd about pane focus and ownership (`DaemonNotifier.send` in the app, no-op in tests).
    private let notify: (Command, String) -> Void
    /// Request/response call to ccgovd (`DaemonClient.request` in the app, nil in tests by default).
    private let request: (Command, String) async -> Response?
    private var sourceTask: Task<Void, Never>?

    init(store: LayoutStore?, claudePath: @escaping @Sendable () -> String?,
         notify: @escaping (Command, String) -> Void = { _, _ in },
         request: @escaping (Command, String) async -> Response? = { _, _ in nil }) {
        self.store = store
        self.claudePath = claudePath
        self.notify = notify
        self.request = request
    }

    // MARK: Sidebar data

    /// Source sessions, plus in-app panes the index does not know about as hibernated rows.
    var rows: [SessionInfo] {
        let inApp = Set(panes.map(\.id))
        var out = sessions.map { s -> SessionInfo in
            var s = s
            s.ownedByApp = inApp.contains(s.sessionId)
            return s
        }
        let indexed = Set(sessions.map(\.sessionId))
        for pane in panes where !indexed.contains(pane.id) {
            out.append(SessionInfo(
                sessionId: pane.id, cwd: pane.cwd, name: pane.title.isEmpty ? nil : pane.title,
                kind: .hibernated, state: pane.hasProcess ? .unknown : .hibernated, ownedByApp: true
            ))
        }
        return out
    }

    var groups: [ProjectGroup] { SessionGrouping.group(rows) }

    func apply(sessions list: [SessionInfo]) {
        freed.update(list)
        sessions = list
    }

    var summary: MemorySummary { MemorySummary(rows: rows, freedBytes: freed.freedBytes) }

    var selectedSession: SessionInfo? {
        guard let id = selectedID else { return nil }
        return rows.first { $0.sessionId == id }
    }

    // MARK: Row actions (docs/design.md step 5)

    /// Shell line that resumes the session in its folder, for the clipboard.
    func resumeCommandLine(_ s: SessionInfo) -> String? {
        ResumeCommand.make(sessionId: s.sessionId, cwd: s.cwd, claude: claudePath() ?? "claude")?.shellLine
    }

    func setPinned(_ s: SessionInfo, _ on: Bool) async {
        await daemonAction(on ? .pin : .unpin, s, done: on ? "Pinned: it will not be hibernated." : "Unpinned.")
    }

    func hibernateNow(_ s: SessionInfo) async {
        await daemonAction(.hibernate, s, done: "Hibernated.")
    }

    private func daemonAction(_ cmd: Command, _ s: SessionInfo, done: String) async {
        guard daemonConnected else {
            notice = "This needs the ccgovd daemon, which is not running."
            return
        }
        guard let resp = await request(cmd, s.sessionId) else {
            notice = "ccgovd did not answer."
            return
        }
        let name = SessionGrouping.displayName(s)
        notice = resp.ok ? "\(name): \(done)" : "\(name): \(resp.error ?? "ccgovd refused the request.")"
    }

    /// ccgovd keeps focus and ownership in memory only. After it (re)starts, tell it again which panes
    /// this app owns and which one is focused, so a visible pane is never governed as unfocused.
    func resyncDaemon() {
        for pane in panes { notify(.attach, pane.id) }
        if let sel = selectedID { notify(.focus, sel) }
    }

    func consume(_ source: SessionSource) {
        sourceTask?.cancel()
        sourceTask = Task { [weak self] in
            for await list in source.updates() {
                guard let self else { return }
                self.apply(sessions: list)
            }
        }
    }

    // MARK: Pane actions

    /// Starts a brand-new session in `cwd` with a fresh UUID.
    func newSession(cwd: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            notice = "Not a directory: \(cwd)"
            return
        }
        let id = UUID().uuidString.lowercased()
        let pane = makePane(sessionId: id, cwd: cwd, title: (cwd as NSString).lastPathComponent, origin: .new)
        panes.append(pane)
        select(pane.id)
    }

    /// Sidebar click.
    func open(_ session: SessionInfo) {
        if panes.contains(where: { $0.id == session.sessionId }) {
            select(session.sessionId)
            return
        }
        guard SessionID.isValid(session.sessionId) else {
            notice = "Session id is not a valid UUID; cannot open it."
            return
        }
        if session.kind == .background {
            notice = "This background session is managed by Claude itself; it is not opened here."
            return
        }
        if session.kind == .interactive {
            // A live interactive record without a pid is still live; resuming it would start a duplicate process.
            let where_ = session.pid.map { "another terminal (pid \($0))" } ?? "another terminal"
            notice = "This session is running in \(where_). Close it there first to open it here."
            return
        }
        let title = session.name ?? (session.cwd as NSString).lastPathComponent
        let pane = makePane(sessionId: session.sessionId, cwd: session.cwd, title: title, origin: .resume)
        panes.append(pane)
        select(pane.id)
    }

    func select(_ id: String?) {
        if let previous = selectedID, previous != id { notify(.unfocus, previous) }
        if let id, let pane = panes.first(where: { $0.id == id }) {
            notify(.focus, id)
            selectedID = id
            launchIfNeeded(pane)
        } else {
            selectedID = nil
        }
        persist()
    }

    func close(_ id: String) {
        guard let idx = panes.firstIndex(where: { $0.id == id }) else { return }
        panes.remove(at: idx)
        notify(.detach, id)
        guard selectedID == id else {
            persist()
            return
        }
        notify(.unfocus, id)
        selectedID = nil
        select(panes.last?.id) // notifies focus, launches lazily, persists
    }

    /// Restore panes from the layout file as placeholders. Only the selected pane launches.
    func restore() {
        guard let store else { return }
        switch store.load() {
        case .empty:
            return
        case .recoveredCorrupt:
            notice = "Saved layout was unreadable; it was moved to layout.json.bad and the app started empty."
        case let .loaded(layout):
            guard let window = layout.windows.first else { return }
            panes = window.panes.compactMap { rec in
                guard SessionID.isValid(rec.sessionId) else { return nil }
                return makePane(sessionId: rec.sessionId, cwd: rec.cwd, title: rec.title, origin: .resume)
            }
            windowFrameForRestore = window.frame
            windowFrame = window.frame // set before select() persists, so the saved frame is not overwritten with nil
            if let sel = window.selected, panes.contains(where: { $0.id == sel }) {
                select(sel)
            }
        }
    }

    /// Frame read from disk at restore; the window view applies it once.
    private(set) var windowFrameForRestore: LayoutFrame?

    // MARK: Internals

    private func makePane(sessionId: String, cwd: String, title: String, origin: Pane.Origin) -> Pane {
        let pane = Pane(sessionId: sessionId, cwd: cwd, title: title, origin: origin)
        notify(.attach, sessionId)
        pane.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        return pane
    }

    private func launchIfNeeded(_ pane: Pane) {
        guard !pane.hasProcess else { return }
        guard let exe = claudePath() else {
            notice = "Could not find the claude binary. Set CCTERM_CLAUDE_PATH or install it at ~/.local/bin/claude."
            return
        }
        do {
            let spec = switch pane.origin {
            case .new: try ClaudeCommand.newSession(id: pane.id, cwd: pane.cwd, executable: exe)
            case .resume: try ClaudeCommand.resume(id: pane.id, cwd: pane.cwd, executable: exe)
            }
            pane.markLaunched(spec)
            objectWillChange.send()
        } catch {
            notice = "Could not start claude: \(error)"
        }
    }

    private func persist() {
        guard let store else { return }
        let window = WindowRecord(
            panes: panes.map { PaneRecord(sessionId: $0.id, cwd: $0.cwd, title: $0.title) },
            selected: selectedID,
            frame: windowFrame
        )
        do { try store.save(LayoutFile(windows: [window])) } catch {
            notice = "Could not save layout: \(error.localizedDescription)"
        }
    }
}

enum DirectoryPicker {
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose the project directory for the new session"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
