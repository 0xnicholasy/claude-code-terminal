import CCProtocol
import Foundation
import Testing
@testable import ClaudeTerm

@MainActor
struct SidebarTests {
    let a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let c = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    let d = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

    func s(_ id: String, _ cwd: String, _ name: String, _ state: SessionState, kind: SessionKind = .interactive,
           owned: Bool = false, rss: UInt64 = 0) -> SessionInfo {
        SessionInfo(sessionId: id, cwd: cwd, name: name, kind: kind, state: state, rssBytes: rss, ownedByApp: owned)
    }

    @Test func openProjectsComeFirstInPaneOrderThenOthersByName() {
        let rows = [
            s(a, "/w/zed", "zed chat", .idle, owned: true),
            s(b, "/w/alpha", "alpha old", .hibernated, kind: .hibernated),
            s(c, "/w/beta", "beta chat", .running, owned: true),
            s(d, "/w/zed", "another", .idle),
        ]
        // Pane order: zed's pane was opened before beta's, so zed is Cmd-1 and must be on top.
        let layout = SidebarLayout.projects(rows, paneOrder: [a, c])
        #expect(layout.open.map(\.name) == ["zed", "beta"])
        #expect(layout.other.map(\.name) == ["alpha"])
        // Inside a project the pane comes first, then the rest by name.
        #expect(layout.open[0].sessions.map(\.sessionId) == [a, d])
        #expect(SidebarLayout.order(rows, paneOrder: [a, c]).map(\.sessionId) == [a, d, c, b])
    }

    @Test func waitingNeverMovesARow() {
        let before = [s(a, "/w/one", "one", .idle, owned: true), s(b, "/w/two", "two", .idle, owned: true)]
        var after = before
        after[1].state = .blocked
        let order = { (rows: [SessionInfo]) in SidebarLayout.order(rows, paneOrder: [a, b]).map(\.sessionId) }
        #expect(order(before) == order(after))
        #expect(SidebarLayout.projects(after, paneOrder: [a, b]).open[1].waiting == 1)
    }

    @Test func newPanesJoinTheirProjectSoShortcutsStayInSidebarOrder() {
        #expect(PaneOrder.insertionIndex(cwds: ["/w/x", "/w/y"], cwd: "/w/x") == 1)
        #expect(PaneOrder.insertionIndex(cwds: ["/w/x", "/w/y"], cwd: "/w/z") == 2)
        #expect(PaneOrder.grouped(["x1", "y1", "x2", "z1", "y2"], key: { String($0.prefix(1)) })
            == ["x1", "x2", "y1", "y2", "z1"])
    }

    @Test func waitingIsAnnouncedOnceAndNotForPromptsSeenAtLaunch() {
        var t = WaitingTracker()
        // Already waiting at the first update: recorded, not announced.
        #expect(t.update([s(a, "/w", "x", .blocked), s(b, "/w", "y", .running)]).started.isEmpty)
        let change = t.update([s(a, "/w", "x", .blocked), s(b, "/w", "y", .blocked)])
        #expect(change.started.map(\.sessionId) == [b])
        // Dropping out of the list for a moment does not re-announce the same prompt.
        _ = t.update([s(a, "/w", "x", .blocked)])
        #expect(t.update([s(a, "/w", "x", .blocked), s(b, "/w", "y", .blocked)]).started.isEmpty)
        // Answered, then waiting again: announced again, and the answer clears the old banner.
        #expect(t.update([s(b, "/w", "y", .running)]).stopped == [b])
        #expect(t.update([s(b, "/w", "y", .blocked)]).started.map(\.sessionId) == [b])
    }

    @Test func notificationButtonsNeedALaunchedPaneAndOneAnswerableTool() {
        func tool(_ id: String, _ name: String = "Bash") -> TranscriptStatus.PendingTool {
            .init(id: id, name: name, summary: "run \(id)", detail: "ls")
        }
        let one = TranscriptStatus(pending: [tool("t1")])
        let plain = PromptContent(category: nil, body: "Waiting for your answer", toolUseId: nil)
        #expect(PromptNotification.content(launched: true, status: one, cwd: "/w")
            == PromptContent(category: "waiting-prompt", body: "Bash: ls", toolUseId: "t1"))
        #expect(PromptNotification.content(launched: false, status: one, cwd: "/w") == plain)
        #expect(PromptNotification.content(launched: true, status: nil, cwd: "/w") == plain)
        #expect(PromptNotification.content(launched: true,
                                           status: TranscriptStatus(pending: [tool("t2", "AskUserQuestion")]),
                                           cwd: "/w") == plain)
        #expect(PromptNotification.content(launched: true,
                                           status: TranscriptStatus(pending: [tool("t1"), tool("t2")]),
                                           cwd: "/w") == plain)
        // A command that does not fit on the row is not shown whole, so no buttons (D15).
        let long = TranscriptStatus.PendingTool(id: "t3", name: "Bash", summary: "x",
                                                detail: String(repeating: "x", count: 61))
        #expect(PromptNotification.content(launched: true, status: TranscriptStatus(pending: [long]), cwd: "/w") == plain)
    }

    @Test func modelReportsNewlyWaitingSessionsAndTheInteractiveCount() {
        var seen: [(WaitingChange, Int)] = []
        let m = WorkspaceModel(store: nil, claudePath: { nil }, attention: { seen.append(($0, $1)) })
        m.apply(sessions: [s(a, "/w", "x", .running), s(b, "/w", "bg", .blocked, kind: .background)])
        m.apply(sessions: [s(a, "/w", "x", .blocked), s(c, "/w", "bg2", .running, kind: .background)])
        m.apply(sessions: [s(a, "/w", "x", .blocked), s(c, "/w", "bg2", .blocked, kind: .background)])
        #expect(seen[2].0.started.isEmpty) // a background agent starting to wait gets no banner
        #expect(seen.count == 3)
        #expect(seen[1].0.started.map(\.sessionId) == [a])
        // Background agents can sit waiting for days: they never count toward the Dock badge.
        #expect(seen[1].1 == 1)
    }

    @Test func freedCountsEachHibernationOnceWithLastLiveMemory() {
        var t = FreedTracker()
        t.update([s(a, "/w", "x", .idle, rss: 300), s(b, "/w", "y", .idle, rss: 100)])
        t.update([s(a, "/w", "x", .idle, rss: 500), s(b, "/w", "y", .idle, rss: 100)])
        t.update([s(a, "/w", "x", .hibernated), s(b, "/w", "y", .idle, rss: 100)])
        t.update([s(a, "/w", "x", .hibernated), s(b, "/w", "y", .idle, rss: 100)]) // still asleep: no double count
        #expect(t.freedBytes == 500)
        // A session that was never seen live adds nothing.
        t.update([s(c, "/w", "z", .hibernated)])
        #expect(t.freedBytes == 500)
    }

    @Test func summaryAddsLiveMemoryAndCountsAsleep() {
        let sum = MemorySummary(rows: [s(a, "/w", "x", .idle, rss: 100), s(b, "/w", "y", .running, rss: 50),
                                       s(c, "/w", "z", .hibernated, kind: .hibernated)], freedBytes: 7)
        #expect(sum == MemorySummary(liveBytes: 150, asleep: 1, freedBytes: 7))
    }

    @Test func elapsedUsesMinutesHoursDays() {
        let now: Int64 = 10 * 86_400_000
        #expect(Formatting.elapsed(sinceMs: now - 5 * 60_000, nowMs: now) == "5 m")
        #expect(Formatting.elapsed(sinceMs: now - 3 * 3_600_000, nowMs: now) == "3 h")
        #expect(Formatting.elapsed(sinceMs: now - 2 * 86_400_000, nowMs: now) == "2 d")
        #expect(Formatting.elapsed(sinceMs: nil, nowMs: now) == nil)
    }

    @Test func daemonActionsNeedTheDaemonAndReportItsAnswer() async {
        var sent: [Command] = []
        let m = WorkspaceModel(store: nil, claudePath: { nil }, request: { cmd, _ in
            sent.append(cmd)
            return Response(id: "1", ok: false, error: "read-only: start the daemon with --govern")
        })
        let row = s(a, "/w", "x", .idle)
        await m.hibernateNow(row)
        #expect(sent.isEmpty && m.notice?.contains("not running") == true)

        m.daemonConnected = true
        await m.hibernateNow(row)
        #expect(sent == [.hibernate] && m.notice?.contains("read-only") == true)
        await m.setPinned(row, true)
        #expect(sent == [.hibernate, .pin])
    }

    @Test func resumeCommandQuotesTheFolder() {
        let m = WorkspaceModel(store: nil, claudePath: { "/usr/bin/claude" })
        #expect(m.resumeCommandLine(s(a, "/w/it's", "x", .idle)) == "cd '/w/it'\\''s' && '/usr/bin/claude' --resume \(a)")
    }
}

@Suite struct ShortcutTests {
    @Test func paneShortcutsMatchGoMenu() {
        #expect(Shortcuts.pane(index: 0, count: 3) == "\u{2318}1")
        #expect(Shortcuts.pane(index: 7, count: 12) == "\u{2318}8")
        #expect(Shortcuts.pane(index: 11, count: 12) == "\u{2318}9")
        #expect(Shortcuts.pane(index: 9, count: 12) == nil)
        #expect(Shortcuts.pane(index: 3, count: 3) == nil)
    }
}
