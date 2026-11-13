import CCProtocol
import Foundation
import GhosttyTerminal
import Testing
@testable import ClaudeTerm

/// These tests exercise the model only. The model never spawns anything: a "launched" pane just
/// holds the LaunchSpec a view would later hand to the terminal. No claude process is started.
@MainActor
struct WorkspaceTests {
    let a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let c = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-test/\(UUID().uuidString)/layout.json")
    }

    func model(_ url: URL) -> WorkspaceModel {
        WorkspaceModel(store: LayoutStore(url: url), claudePath: { "/usr/bin/claude-fake" })
    }

    @Test func layoutRoundTripsThroughDisk() throws {
        let url = scratchURL()
        let layout = LayoutFile(windows: [WindowRecord(
            panes: [PaneRecord(sessionId: a, cwd: "/w/a", title: "A"), PaneRecord(sessionId: b, cwd: "/w/b", title: "B")],
            selected: b, frame: LayoutFrame(x: 10, y: 20, width: 900, height: 600))])
        let store = LayoutStore(url: url)
        try store.save(layout)
        #expect(store.load() == .loaded(layout))
    }

    @Test func corruptLayoutIsBackedUpAndTheAppStartsEmpty() throws {
        let url = scratchURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)

        let m = model(url)
        m.restore()

        #expect(m.panes.isEmpty)
        #expect(m.notice != nil)
        #expect(try Data(contentsOf: url.appendingPathExtension("bad")) == Data("{not json".utf8))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func restoredPanesHaveNoProcessUntilSelected() throws {
        let url = scratchURL()
        try LayoutStore(url: url).save(LayoutFile(windows: [WindowRecord(
            panes: [PaneRecord(sessionId: a, cwd: "/w/a", title: "A"),
                    PaneRecord(sessionId: b, cwd: "/w/b", title: "B"),
                    PaneRecord(sessionId: c, cwd: "/w/c", title: "C")],
            selected: nil, frame: nil)]))

        let m = model(url)
        m.restore()
        #expect(m.panes.count == 3)
        #expect(m.panes.allSatisfy { !$0.hasProcess })

        m.select(b)
        #expect(m.panes.filter(\.hasProcess).map(\.id) == [b])
        #expect(m.panes.first { $0.id == b }?.launched?.argv == ["/usr/bin/claude-fake", "--resume", b])
        #expect(m.panes.first { $0.id == b }?.launched?.cwd == "/w/b")
    }

    @Test func restoreKeepsTheSavedWindowFrameOnDisk() throws {
        let url = scratchURL()
        let frame = LayoutFrame(x: 10, y: 20, width: 1000, height: 640)
        try LayoutStore(url: url).save(LayoutFile(windows: [WindowRecord(
            panes: [PaneRecord(sessionId: a, cwd: "/w/a", title: "A")], selected: a, frame: frame)]))
        let m = model(url)
        m.restore() // select() persists during restore; the frame must survive that write
        guard case let .loaded(after) = LayoutStore(url: url).load() else {
            Issue.record("layout not written")
            return
        }
        #expect(after.windows.first?.frame == frame)
    }

    @Test func liveInteractiveSessionWithoutPidIsNotResumed() {
        let m = model(scratchURL())
        m.open(SessionInfo(sessionId: a, cwd: "/w/a", kind: .interactive, state: .idle))
        #expect(m.panes.isEmpty)
        #expect(m.notice != nil)
    }

    @Test func launchOnRestoreOnlyForTheSavedSelection() throws {
        let url = scratchURL()
        try LayoutStore(url: url).save(LayoutFile(windows: [WindowRecord(
            panes: [PaneRecord(sessionId: a, cwd: "/w/a", title: "A"), PaneRecord(sessionId: b, cwd: "/w/b", title: "B")],
            selected: a, frame: nil)]))
        let m = model(url)
        m.restore()
        #expect(m.panes.filter(\.hasProcess).map(\.id) == [a])
    }

    @Test func layoutIsWrittenOnEveryChange() throws {
        let url = scratchURL()
        let m = model(url)
        let dir = url.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        m.newSession(cwd: dir)
        guard case let .loaded(first) = LayoutStore(url: url).load() else {
            Issue.record("layout not written after newSession")
            return
        }
        let id = try #require(first.windows.first?.panes.first?.sessionId)
        #expect(first.windows.first?.selected == id)
        #expect(m.panes.first?.launched?.arguments == ["--session-id", id])

        m.close(id)
        #expect(LayoutStore(url: url).load() == .loaded(LayoutFile(windows: [WindowRecord(panes: [], selected: nil, frame: nil)])))
    }

    @Test func sidebarClickRespectsOwnershipAndShowsHibernatedPanes() {
        let m = model(scratchURL())
        let live = SessionInfo(sessionId: a, cwd: "/w/a", kind: .interactive, state: .idle, pid: 4242)
        m.open(live)
        #expect(m.panes.isEmpty)
        #expect(m.notice?.contains("4242") == true)

        let bg = SessionInfo(sessionId: c, cwd: "/w/c", kind: .background, state: .blocked)
        m.open(bg)
        #expect(m.panes.isEmpty)

        m.notice = nil
        let dormant = SessionInfo(sessionId: b, cwd: "/w/b", kind: .hibernated, state: .hibernated)
        m.open(dormant)
        #expect(m.notice == nil)
        #expect(m.panes.first?.launched?.argv == ["/usr/bin/claude-fake", "--resume", b])

        let invalid = SessionInfo(sessionId: "not-a-uuid", cwd: "/w/x", kind: .hibernated, state: .hibernated)
        m.open(invalid)
        #expect(m.panes.count == 1)

        // A pane unknown to the index appears as a hibernated/in-app row; an indexed one is marked owned.
        m.apply(sessions: [live])
        #expect(m.rows.contains { $0.sessionId == b && $0.ownedByApp })
        #expect(m.rows.count == 2)
    }

    // MARK: Answering prompts

    /// A model with one launched pane `a`, a recorder for sent keys and a settable fresh status.
    func promptModel(state: SessionState = .blocked, launch: Bool = true,
                     status: TranscriptStatus? = TranscriptStatus(pending: [.init(id: "t1", name: "Bash", summary: "Bash", detail: "ls")]),
                     sendResult: Bool = true, sent: SentKeys) -> WorkspaceModel {
        let m = WorkspaceModel(store: LayoutStore(url: scratchURL()), claudePath: { "/usr/bin/claude-fake" },
                               promptStatus: { _ in status },
                               sendKey: { pane, key in sent.keys.append((pane.id, key)); return sendResult })
        m.open(SessionInfo(sessionId: a, cwd: "/w/a", kind: .hibernated, state: .hibernated))
        if !launch { m.panes.first?.markExited() }
        m.apply(sessions: [SessionInfo(sessionId: a, cwd: "/w/a", kind: .interactive, state: state)])
        return m
    }

    final class SentKeys {
        var keys: [(String, TerminalKey)] = []
    }

    @Test func answerSendsOneForAllowAndEscapeForDeny() {
        let sent = SentKeys()
        let m = promptModel(sent: sent)
        m.answer(sessionId: a, toolUseId: "t1", allow: true)
        m.answer(sessionId: a, toolUseId: "t1", allow: false)
        #expect(sent.keys.map(\.1) == [.digit1, .escape])
        #expect(sent.keys.allSatisfy { $0.0 == a })
        #expect(m.notice == nil)
    }

    @Test func answerSendsNothingWhenNotBlocked() {
        let sent = SentKeys()
        let m = promptModel(state: .running, sent: sent)
        m.answer(sessionId: a, toolUseId: "t1", allow: true)
        #expect(sent.keys.isEmpty)
        #expect(m.notice == PromptAnswer.staleNotice)
    }

    @Test func answerSendsNothingWhenThePendingToolChanged() {
        let sent = SentKeys()
        let m = promptModel(sent: sent)
        m.answer(sessionId: a, toolUseId: "other", allow: true)
        #expect(sent.keys.isEmpty)
        #expect(m.notice == PromptAnswer.staleNotice)
    }

    @Test func answerSendsNothingWithTwoPendingTools() {
        let sent = SentKeys()
        let two = TranscriptStatus(pending: [.init(id: "t1", name: "Bash", summary: "Bash", detail: "ls"),
                                             .init(id: "t2", name: "Edit", summary: "Edit", detail: "/w/a/f")])
        let m = promptModel(status: two, sent: sent)
        m.answer(sessionId: a, toolUseId: "t1", allow: true)
        #expect(sent.keys.isEmpty)
        #expect(m.notice == PromptAnswer.staleNotice)
    }

    @Test func answerSendsNothingForAnExcludedTool() {
        let sent = SentKeys()
        let plan = TranscriptStatus(pending: [.init(id: "t1", name: "ExitPlanMode", summary: "plan")])
        let m = promptModel(status: plan, sent: sent)
        m.answer(sessionId: a, toolUseId: "t1", allow: true)
        #expect(sent.keys.isEmpty)
        #expect(m.notice == PromptAnswer.staleNotice)
    }

    @Test func answerChecksAFileToolAgainstThePanesFolder() {
        func edit(_ path: String) -> TranscriptStatus {
            TranscriptStatus(pending: [.init(id: "t1", name: "Edit", summary: "Edit", detail: path)])
        }
        let inside = SentKeys()
        promptModel(status: edit("/w/a/src/x.swift"), sent: inside).answer(sessionId: a, toolUseId: "t1", allow: true)
        #expect(inside.keys.map(\.1) == [.digit1])
        let outside = SentKeys()
        let m = promptModel(status: edit("/w/b/x.swift"), sent: outside)
        m.answer(sessionId: a, toolUseId: "t1", allow: true)
        #expect(outside.keys.isEmpty)
        #expect(m.notice == PromptAnswer.staleNotice)
    }

    @Test func answerSendsNothingForACommandTooLongToShowWhole() {
        let sent = SentKeys()
        let long = TranscriptStatus(pending: [.init(id: "t1", name: "Bash", summary: "Bash",
                                                    detail: String(repeating: "x", count: 61))])
        let m = promptModel(status: long, sent: sent)
        m.answer(sessionId: a, toolUseId: "t1", allow: true)
        #expect(sent.keys.isEmpty)
        #expect(m.notice == PromptAnswer.staleNotice)
    }

    @Test func answerSendsNothingForAPaneWithoutAProcess() {
        let sent = SentKeys()
        let m = promptModel(launch: false, sent: sent)
        m.answer(sessionId: a, toolUseId: "t1", allow: true)
        #expect(sent.keys.isEmpty)
        #expect(m.notice == PromptAnswer.staleNotice)
    }

    @Test func answerSendsNothingWhenTheFreshStatusIsMissing() {
        let sent = SentKeys()
        let m = promptModel(status: nil, sent: sent)
        m.answer(sessionId: a, toolUseId: "t1", allow: true)
        #expect(sent.keys.isEmpty)
        #expect(m.notice == PromptAnswer.staleNotice)
    }

    @Test func answerReportsAFailedKeySend() {
        let sent = SentKeys()
        let m = promptModel(sendResult: false, sent: sent)
        m.answer(sessionId: a, toolUseId: "t1", allow: true)
        #expect(sent.keys.count == 1)
        #expect(m.notice == PromptAnswer.failedSendNotice)
    }

    // MARK: Worktree sessions (T15)

    func worktreeModel(_ url: URL, root: String?) -> WorkspaceModel {
        WorkspaceModel(store: LayoutStore(url: url), claudePath: { "/usr/bin/claude-fake" }, repoRoot: { _ in root })
    }

    @Test func worktreeSessionLaunchesFromTheRepoRootAndLivesInTheWorktree() async throws {
        let url = scratchURL()
        let repo = "/nonexistent-ccterm/repo"
        let m = worktreeModel(url, root: repo)
        m.newSession(cwd: "/tmp")
        await m.newWorktreeSession(from: repo + "/sub", name: "feat-1")

        let pane = try #require(m.panes.last)
        let wt = repo + "/.claude/worktrees/feat-1"
        #expect(m.selectedID == pane.id)
        #expect(pane.cwd == wt)
        #expect(pane.launched?.arguments == ["--session-id", pane.id, "-w", "feat-1"])
        #expect(pane.launched?.cwd == repo)

        guard case let .loaded(saved) = LayoutStore(url: url).load() else {
            Issue.record("layout not saved")
            return
        }
        #expect(saved.windows.first?.panes.last == PaneRecord(sessionId: pane.id, cwd: wt, title: "feat-1"))

        // Restore resumes in the worktree, without -w.
        let restored = model(url)
        restored.restore()
        let again = try #require(restored.panes.first { $0.id == pane.id })
        #expect(again.launched?.argv == ["/usr/bin/claude-fake", "--resume", pane.id])
        #expect(again.launched?.cwd == wt)
    }

    @Test func worktreeSessionStartedFromAWorktreeUsesItsRepo() async throws {
        let repo = "/nonexistent-ccterm/repo"
        let m = worktreeModel(scratchURL(), root: repo + "/.claude/worktrees/old")
        await m.newWorktreeSession(from: repo + "/.claude/worktrees/old", name: "next")
        let pane = try #require(m.panes.first)
        #expect(pane.cwd == repo + "/.claude/worktrees/next")
        #expect(pane.launched?.cwd == repo)
    }

    @Test func worktreePaneSitsNextToItsProjectsPanes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccterm-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let m = worktreeModel(scratchURL(), root: root)
        m.newSession(cwd: root)
        m.newSession(cwd: "/usr")
        await m.newWorktreeSession(from: root, name: "wt-a")
        await m.newWorktreeSession(from: root, name: "wt-b")
        #expect(m.panes.map(\.cwd) == [root, root + "/.claude/worktrees/wt-a", root + "/.claude/worktrees/wt-b", "/usr"])
    }

    @Test func worktreeNameStillStartingIsRefused() async {
        let m = worktreeModel(scratchURL(), root: "/nonexistent-ccterm/repo")
        await m.newWorktreeSession(from: "/nonexistent-ccterm/repo", name: "dup")
        await m.newWorktreeSession(from: "/nonexistent-ccterm/repo", name: "dup")
        #expect(m.panes.count == 1)
        #expect(m.notice?.contains("already exists") == true)
    }

    @Test func worktreeSessionRefusesNonReposBadNamesAndExistingWorktrees() async throws {
        let m = worktreeModel(scratchURL(), root: nil)
        await m.newWorktreeSession(from: "/tmp", name: "ok")
        #expect(m.panes.isEmpty)
        #expect(m.notice == "Not a git repository: /tmp")

        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("ccterm-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo + "/.claude/worktrees/taken", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let r = worktreeModel(scratchURL(), root: repo)
        await r.newWorktreeSession(from: repo, name: "-x")
        #expect(r.panes.isEmpty)
        #expect(r.notice?.hasPrefix("Invalid worktree name") == true)
        await r.newWorktreeSession(from: repo, name: "taken")
        #expect(r.panes.isEmpty)
        #expect(r.notice?.contains("already exists") == true)
    }
}
