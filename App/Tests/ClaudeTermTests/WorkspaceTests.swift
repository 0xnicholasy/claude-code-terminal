import CCProtocol
import Foundation
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
}
