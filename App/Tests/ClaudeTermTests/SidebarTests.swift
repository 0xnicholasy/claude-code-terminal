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

    @Test func sectionsFollowWhatTheUserCanDoInFixedOrder() {
        let rows = [
            s(a, "/w/one", "one", .idle),                                   // live elsewhere
            s(b, "/w/two", "two", .blocked, owned: true),                   // blocked wins over owned
            s(c, "/w/three", "three", .running, owned: true),
            s(d, "/w/four", "four", .hibernated, kind: .hibernated),
        ]
        let sections = SidebarLayout.sections(rows)
        #expect(sections.map(\.kind) == [.needsYou, .openHere, .elsewhere, .asleep])
        #expect(sections[0].entries.map(\.id) == [b])
        #expect(sections[1].entries.map(\.id) == [c])
        #expect(sections[3].entries.map(\.id) == [d])
        // Empty sections are dropped.
        #expect(SidebarLayout.sections([rows[0]]).map(\.kind) == [.elsewhere])
    }

    @Test func sessionsSharingAProjectCollapseIntoOneEntry() {
        let rows = [s(a, "/w/omen", "omen-24", .idle), s(b, "/w/omen", "omen-53", .idle), s(c, "/w/zed", "zed", .idle)]
        let entries = SidebarLayout.sections(rows)[0].entries
        #expect(entries.count == 2)
        guard case let .project(path, name, sessions) = entries[0] else {
            Issue.record("expected a project entry first")
            return
        }
        #expect(path == "/w/omen" && name == "omen" && sessions.map(\.sessionId) == [a, b])
        #expect(entries[1] == .session(rows[2]))
    }

    @Test func projectNameShownOnlyWhenItAddsInformation() {
        #expect(SidebarLayout.secondaryText(s(a, "/w/omen", "omen-24", .idle)) == nil)
        #expect(SidebarLayout.secondaryText(s(a, "/w/omen", "Fix login bug", .idle)) == "omen")
    }

    @Test func memoryBarScalesToTheLargestLiveSession() {
        #expect(SidebarLayout.memoryFraction(s(a, "/w", "x", .idle, rss: 512), maxBytes: 1024) == 0.5)
        #expect(SidebarLayout.memoryFraction(s(a, "/w", "x", .hibernated, rss: 512), maxBytes: 1024) == 0)
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
