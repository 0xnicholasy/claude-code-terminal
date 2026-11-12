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

    /// Presses a key in this pane's terminal. False when there is no terminal to receive it.
    /// Never paste text here: a key press is the only input path for answering a prompt.
    func send(_ key: TerminalKey) -> Bool {
        terminal?.sendKey(key) ?? false
    }

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
    /// The same applies to Ghostty's tab and split keybinds, which would swallow the app's Go menu.
    /// Names as `ghostty +list-keybinds --default` prints them (Ghostty 1.x).
    static let unboundKeys = ["super+q", "super+n", "super+shift+w", "ctrl+tab", "ctrl+shift+tab",
                              "super+shift+[", "super+shift+]", "super+alt+arrow_up", "super+alt+arrow_down",
                              "super+shift+v", "super+shift+m"]
        + (1...9).flatMap { ["super+\($0)", "super+digit_\($0)"] }
    /// Warm palette matching the window chrome (`Palette.main`), after the Claude desktop app. Theme
    /// commands are applied after the builder's, so colours set in the builder would be overwritten.
    static let theme = TerminalTheme(
        light: TerminalConfiguration { b in
            b.withBackground("FAF9F5")
            b.withForeground("262624")
            b.withCursorColor("C6613F")
            b.withSelectionBackground("F2D5C8")
            b.withSelectionForeground("262624")
            for (i, c) in ["262624", "B6412F", "4E7A3A", "94650F", "2F6596", "8E4A7A", "2F7F78", "B8B5AA",
                           "87867F", "C6513A", "5C8C46", "A87512", "3B76AB", "A2588C", "36918A", "D9D6CC"].enumerated() {
                b.withPalette(i, color: "#" + c)
            }
        },
        dark: TerminalConfiguration { b in
            b.withBackground("262624")
            b.withForeground("E8E6DC")
            b.withCursorColor("D97757")
            b.withSelectionBackground("5A3E33")
            b.withSelectionForeground("FAF9F5")
            for (i, c) in ["1F1E1D", "E06C5A", "8DB57A", "E3B26B", "7AA2C8", "C88BB0", "7CC2B8", "E8E6DC",
                           "6B6A65", "EE8572", "A3C891", "EDC285", "94B6D8", "D9A2C4", "96D2C9", "FAF9F5"].enumerated() {
                b.withPalette(i, color: "#" + c)
            }
        }
    )
    static let sharedController = TerminalController(theme: theme) { config in
        for key in unboundKeys { config.withCustom("keybind", "\(key)=unbind") }
        // Breathing room between the terminal text and the sidebar / status strip.
        config.withCustom("window-padding-x", "12")
        config.withCustom("window-padding-y", "8")
        config.withCustom("window-padding-balance", "true")
    }

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
    @Published var tab: DetailTab = .sessions
    /// Panes whose claude is being stopped by Close Pane.
    @Published private(set) var closing: Set<String> = []
    private var waiting = WaitingTracker()

    var windowFrame: LayoutFrame? {
        didSet { if windowFrame != oldValue { persist() } }
    }

    private let store: LayoutStore?
    private let claudePath: @Sendable () -> String?
    /// Tells ccgovd about pane focus and ownership (`DaemonNotifier.send` in the app, no-op in tests).
    private let notify: (Command, String) -> Void
    /// Request/response call to ccgovd (`DaemonClient.request` in the app, nil in tests by default).
    private let request: (Command, String) async -> Response?
    /// Signals processes for Take Over (`SystemProcessControl` in the app, a fake in tests).
    private let processes: ProcessControl
    /// Asks the user before Take Over stops a process (an alert in the app).
    private let confirm: (SessionInfo) -> Bool
    /// The pid of the claude a pane started (`PaneProcess.claudePid` in the app, nil in tests).
    private let paneProcess: (String) -> Int32?
    /// Sessions that just started or stopped waiting, plus how many interactive sessions wait now
    /// (`AttentionNotifier` in the app: notification banner and Dock badge; no-op in tests).
    private let attention: (WaitingChange, Int) -> Void
    /// A fresh tail-parse of a session's transcript, by session id (wired in Bootstrap; nil in tests by default).
    private let promptStatus: (String) -> TranscriptStatus?
    /// Presses a key in a pane (`Pane.send` in the app, a recorder in tests).
    private let sendKey: (Pane, TerminalKey) -> Bool
    private var sourceTask: Task<Void, Never>?

    init(store: LayoutStore?, claudePath: @escaping @Sendable () -> String?,
         notify: @escaping (Command, String) -> Void = { _, _ in },
         request: @escaping (Command, String) async -> Response? = { _, _ in nil },
         processes: ProcessControl = SystemProcessControl(),
         confirm: @escaping (SessionInfo) -> Bool = { _ in false },
         paneProcess: @escaping (String) -> Int32? = { _ in nil },
         attention: @escaping (WaitingChange, Int) -> Void = { _, _ in },
         promptStatus: @escaping (String) -> TranscriptStatus? = { _ in nil },
         sendKey: @escaping (Pane, TerminalKey) -> Bool = { $0.send($1) }) {
        self.paneProcess = paneProcess
        self.attention = attention
        self.promptStatus = promptStatus
        self.sendKey = sendKey
        self.store = store
        self.claudePath = claudePath
        self.notify = notify
        self.request = request
        self.processes = processes
        self.confirm = confirm
    }

    // MARK: Sidebar data

    /// Source sessions, plus in-app panes the index does not know about as hibernated rows.
    var rows: [SessionInfo] {
        let paneCwd = Dictionary(panes.map { ($0.id, $0.cwd) }, uniquingKeysWith: { a, _ in a })
        var out = sessions.map { s -> SessionInfo in
            var s = s
            s.ownedByApp = paneCwd[s.sessionId] != nil
            // The pane's folder wins, so the row sits in the same project group as its pane.
            if let cwd = paneCwd[s.sessionId] { s.cwd = cwd }
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
        let current = rows
        var change = waiting.update(current)
        // Background agents can sit waiting for days; like the badge, banners cover interactive sessions only.
        change.started.removeAll { $0.kind == .background }
        attention(change, current.filter { $0.state == .blocked && $0.kind != .background }.count)
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
        insert(pane)
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
            notice = "This session is running in \(where_). Right-click it and choose Take Over to move it here."
            return
        }
        openResumePane(session)
    }

    /// True when Take Over applies: a live interactive session in another terminal.
    func canTakeOver(_ s: SessionInfo) -> Bool {
        s.kind == .interactive && s.pid != nil && !s.ownedByApp
            && !panes.contains { $0.id == s.sessionId }
    }

    /// Stops the claude process in the other terminal (after confirmation), then resumes the
    /// session in a pane here. The other terminal's tab is left at its shell prompt.
    func takeOver(_ session: SessionInfo) async {
        guard canTakeOver(session), SessionID.isValid(session.sessionId) else { return }
        guard confirm(session) else { return }
        if let refusal = await Takeover.stop(pid: session.pid, control: processes) {
            notice = Takeover.message(refusal)
            return
        }
        guard !panes.contains(where: { $0.id == session.sessionId }) else { return }
        openResumePane(session)
    }

    private func openResumePane(_ session: SessionInfo) {
        let title = session.name ?? (session.cwd as NSString).lastPathComponent
        let pane = makePane(sessionId: session.sessionId, cwd: session.cwd, title: title, origin: .resume)
        insert(pane)
        select(pane.id)
    }

    /// Next to the project's other panes, so Cmd-numbers keep following the sidebar top to bottom.
    private func insert(_ pane: Pane) {
        panes.insert(pane, at: PaneOrder.insertionIndex(cwds: panes.map(\.cwd), cwd: pane.cwd))
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

    // MARK: Keyboard navigation

    /// Cmd-1 ... Cmd-9: the Nth open pane; Cmd-9 is always the last one, as in browsers.
    func selectPane(number n: Int) {
        guard !panes.isEmpty, n >= 1 else { return }
        let idx = n == 9 ? panes.count - 1 : n - 1
        guard idx < panes.count else { return }
        tab = .sessions
        select(panes[idx].id)
    }

    /// Next or previous open pane, wrapping around.
    func cyclePane(by step: Int) {
        guard !panes.isEmpty else { return }
        let cur = panes.firstIndex { $0.id == selectedID } ?? (step > 0 ? -1 : 0)
        let next = ((cur + step) % panes.count + panes.count) % panes.count
        tab = .sessions
        select(panes[next].id)
    }

    /// Next or previous row in sidebar order (all sessions, not only open panes), wrapping around.
    /// Opening a row follows the click rules, so a session live elsewhere shows its notice.
    func cycleSession(by step: Int) {
        let order = SidebarLayout.order(rows, paneOrder: panes.map(\.id))
        guard !order.isEmpty else { return }
        let cur = order.firstIndex { $0.sessionId == selectedID } ?? (step > 0 ? -1 : 0)
        let next = ((cur + step) % order.count + order.count) % order.count
        tab = .sessions
        open(order[next])
    }

    /// Cmd-Shift-N: another session in the selected pane's project.
    func newSessionInCurrentProject() {
        guard let cwd = selectedSession?.cwd, !cwd.isEmpty else {
            notice = "Select a pane first: the new session starts in its project folder."
            return
        }
        newSession(cwd: cwd)
    }

    /// Answers a pending permission prompt with a key press. The transcript is re-read first, so a
    /// prompt that was answered or replaced since the button was shown is never answered blindly.
    func answer(sessionId: String, toolUseId: String, allow: Bool) {
        guard let pane = panes.first(where: { $0.id == sessionId }),
              let state = rows.first(where: { $0.sessionId == sessionId })?.state,
              PromptAnswer.canSend(state: state, shownToolUseId: toolUseId,
                                   current: promptStatus(sessionId), hasProcess: pane.hasProcess,
                                   cwd: pane.cwd) else {
            notice = PromptAnswer.staleNotice
            return
        }
        if !sendKey(pane, PromptAnswer.keys(allow: allow)) {
            notice = PromptAnswer.failedSendNotice
        }
    }

    /// Removes the pane and ends its claude. Closing the view alone left claude running in the
    /// background (seen live 2026-11-07); SIGTERM lets it save the transcript, so the session can be
    /// resumed later from the sidebar.
    func close(_ id: String) {
        guard let idx = panes.firstIndex(where: { $0.id == id }) else { return }
        let pane = panes.remove(at: idx)
        if pane.hasProcess, let pid = paneProcess(id) {
            closing.insert(id)
            let control = processes
            Task {
                // SessionEnd hooks can delay exit by several seconds; allow 20 s before reporting.
                if await Takeover.stop(pid: pid, control: control, timeout: .seconds(20)) != nil {
                    notice = "Closed the pane, but its claude (pid \(pid)) did not stop. It now shows under Elsewhere."
                }
                closing.remove(id)
            }
        }
        pane.markExited()
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
            panes = PaneOrder.grouped(window.panes.compactMap { rec in
                guard SessionID.isValid(rec.sessionId) else { return nil }
                return makePane(sessionId: rec.sessionId, cwd: rec.cwd, title: rec.title, origin: .resume)
            }, key: \.cwd)
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

extension WorkspaceModel {
    /// The Cmd-number shortcut that selects this session's pane, when it has one.
    func paneShortcut(_ id: String) -> String? {
        guard let idx = panes.firstIndex(where: { $0.id == id }) else { return nil }
        return Shortcuts.pane(index: idx, count: panes.count)
    }

    /// 1-based position of the selected pane, for "2 of 5" in the status strip.
    var selectedPanePosition: (index: Int, count: Int)? {
        guard let idx = panes.firstIndex(where: { $0.id == selectedID }) else { return nil }
        return (idx + 1, panes.count)
    }
}
