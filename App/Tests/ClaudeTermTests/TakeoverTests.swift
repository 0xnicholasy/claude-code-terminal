import CCProtocol
import Darwin
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ClaudeTerm

/// Fake process table. No real process is ever signalled in these tests.
final class FakeProcesses: ProcessControl, @unchecked Sendable {
    // @unchecked: test-only fake; tests touch it from one task at a time, guarded by `lock`.
    private let lock = NSLock()
    private var table: [Int32: ProcIdentity]
    private(set) var signalled: [(Int32, Int32)] = []
    /// When true, the process exits on SIGTERM.
    var exitsOnTerm: Bool

    init(_ table: [Int32: ProcIdentity], exitsOnTerm: Bool = true) {
        self.table = table
        self.exitsOnTerm = exitsOnTerm
    }

    func identity(_ pid: Int32) -> ProcIdentity? { lock.withLock { table[pid] } }

    func signal(_ pid: Int32, _ sig: Int32) -> Bool {
        lock.withLock {
            signalled.append((pid, sig))
            if exitsOnTerm, sig == SIGTERM { table[pid] = nil }
            return true
        }
    }
}

@MainActor
struct TakeoverTests {
    let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let me = getuid()

    func claude(uid: uid_t? = nil, path: String = "/Users/x/.local/share/claude/versions/2.1.319") -> ProcIdentity {
        ProcIdentity(uid: uid ?? me, startSec: 100, startUsec: 5, path: path)
    }

    func session(pid: Int32?) -> SessionInfo {
        SessionInfo(sessionId: id, cwd: "/w/proj", name: "proj-1", kind: .interactive, state: .idle, pid: pid)
    }

    @Test func refusesProcessesThatAreNotClaudeOrNotMine() {
        let fake = FakeProcesses([10: claude(path: "/bin/zsh"), 11: claude(uid: me + 1), 12: claude()])
        #expect(Takeover.verify(pid: 10, control: fake) == .failure(.notClaude("/bin/zsh")))
        #expect(Takeover.verify(pid: 11, control: fake) == .failure(.otherUser))
        #expect(Takeover.verify(pid: 1, control: fake) == .failure(.protectedPid))
        #expect(Takeover.verify(pid: 77, control: fake, selfPid: 77) == .failure(.protectedPid))
        #expect(Takeover.verify(pid: 99, control: fake) == .failure(.gone))
        #expect(Takeover.verify(pid: 12, control: fake) == .success(claude()))
    }

    @Test func stopSendsOnlySigtermAndOnlyToTheVerifiedPid() async {
        let fake = FakeProcesses([10: claude(path: "/bin/zsh"), 12: claude()])
        #expect(await Takeover.stop(pid: 10, control: fake) == .notClaude("/bin/zsh"))
        #expect(fake.signalled.isEmpty)
        #expect(await Takeover.stop(pid: 12, control: fake) == nil)
        #expect(fake.signalled.map(\.0) == [12])
        #expect(fake.signalled.map(\.1) == [SIGTERM])
    }

    @Test func aProcessThatIgnoresSigtermIsNotKilled() async {
        let fake = FakeProcesses([12: claude()], exitsOnTerm: false)
        #expect(await Takeover.stop(pid: 12, control: fake, timeout: .milliseconds(300)) == .didNotExit)
        #expect(!fake.signalled.contains { $0.1 == SIGKILL })
    }

    @Test func takeOverResumesHereOnlyAfterConfirmAndExit() async {
        let fake = FakeProcesses([12: claude()])
        let declined = WorkspaceModel(store: nil, claudePath: { "/usr/bin/claude-fake" },
                                      processes: fake, confirm: { _ in false })
        await declined.takeOver(session(pid: 12))
        #expect(declined.panes.isEmpty)
        #expect(fake.signalled.isEmpty)

        let m = WorkspaceModel(store: nil, claudePath: { "/usr/bin/claude-fake" },
                               processes: fake, confirm: { _ in true })
        await m.takeOver(session(pid: 12))
        #expect(m.panes.map(\.id) == [id])
        #expect(m.selectedID == id)
        #expect(m.panes.first?.launched?.ghosttyCommand.contains("--resume \(id)") == true)
    }

    @Test func refusedTakeOverOpensNothing() async {
        let fake = FakeProcesses([12: claude(path: "/usr/bin/vim")])
        let m = WorkspaceModel(store: nil, claudePath: { "/usr/bin/claude-fake" },
                               processes: fake, confirm: { _ in true })
        await m.takeOver(session(pid: 12))
        #expect(m.panes.isEmpty)
        #expect(m.notice != nil)
        #expect(fake.signalled.isEmpty)
    }

    @Test func oneProjectHoldsSeveralSessions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccterm-test/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = WorkspaceModel(store: nil, claudePath: { "/usr/bin/claude-fake" })
        m.newSession(cwd: dir.path)
        m.newSession(cwd: dir.path)
        #expect(m.panes.count == 2)
        #expect(Set(m.panes.map(\.id)).count == 2)
        let layout = SidebarLayout.projects(m.rows, paneOrder: m.panes.map(\.id))
        #expect(layout.open.count == 1)
        #expect(layout.open.first?.sessions.count == 2)
    }
}

@MainActor
struct NavigationTests {
    func dirs(_ n: Int) throws -> [String] {
        try (0..<n).map { i in
            let d = FileManager.default.temporaryDirectory.appendingPathComponent("ccterm-test/nav-\(UUID().uuidString)-\(i)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d.path
        }
    }

    @Test func numberAndCycleShortcutsMoveBetweenPanes() throws {
        let m = WorkspaceModel(store: nil, claudePath: { "/usr/bin/claude-fake" })
        for d in try dirs(3) { m.newSession(cwd: d) }
        let ids = m.panes.map(\.id)
        m.selectPane(number: 1)
        #expect(m.selectedID == ids[0])
        m.selectPane(number: 9) // last pane
        #expect(m.selectedID == ids[2])
        m.selectPane(number: 5) // no fifth pane: unchanged
        #expect(m.selectedID == ids[2])
        m.cyclePane(by: 1) // wraps
        #expect(m.selectedID == ids[0])
        m.cyclePane(by: -1)
        #expect(m.selectedID == ids[2])
        m.tab = .usage
        m.cyclePane(by: 1)
        #expect(m.tab == .sessions)
    }

    @Test func newSessionInCurrentProjectUsesTheSelectedPaneFolder() throws {
        let m = WorkspaceModel(store: nil, claudePath: { "/usr/bin/claude-fake" })
        m.newSessionInCurrentProject()
        #expect(m.panes.isEmpty && m.notice != nil)
        let d = try dirs(1)[0]
        m.newSession(cwd: d)
        m.newSessionInCurrentProject()
        #expect(m.panes.count == 2)
        #expect(m.panes.allSatisfy { $0.cwd == d })
    }
}

@MainActor
struct ClosePaneTests {
    let id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let claude = ProcIdentity(uid: getuid(), startSec: 1, startUsec: 1, path: "/Users/x/.local/share/claude/versions/2.1.319")

    @Test func closeSendsSigtermToThePanesClaudeOnly() async throws {
        let fake = FakeProcesses([40: claude, 41: claude])
        let model = WorkspaceModel(store: nil, claudePath: { "/usr/local/bin/claude" }, processes: fake,
                                   paneProcess: { _ in 40 })
        model.newSession(cwd: "/tmp")
        let pid = try #require(model.panes.first?.id)
        #expect(model.panes.first?.hasProcess == true)
        model.close(pid)
        #expect(model.panes.isEmpty)
        for _ in 0..<50 where !model.closing.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fake.signalled.map(\.0) == [40])
        #expect(fake.signalled.map(\.1) == [SIGTERM])
    }

    @Test func descendantCheckRejectsProcessesOutsideTheAppTree() {
        let parents: [Int32: Int32] = [500: 100, 501: 500, 502: 501, 900: 1, 901: 900]
        #expect(PaneProcess.isDescendant(502, of: 100, parents: parents))
        #expect(!PaneProcess.isDescendant(901, of: 100, parents: parents))
        #expect(!PaneProcess.isDescendant(100, of: 100, parents: parents))
    }

    @Test func parsesProcArgs() {
        var buf: [UInt8] = [3, 0, 0, 0]
        buf += Array("/bin/claude".utf8) + [0, 0, 0]
        for a in ["claude", "--resume", "bbbb"] { buf += Array(a.utf8) + [0] }
        buf += Array("PATH=/x".utf8) + [0]
        #expect(PaneProcess.parseProcArgs(buf) == ["claude", "--resume", "bbbb"])
    }

    @Test func linkPolicyOpensWebMailFileOnly() {
        #expect(LinkPolicy.url("https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(LinkPolicy.url("mailto:a@b.c") != nil)
        #expect(LinkPolicy.url("/Users/x/file.swift")?.isFileURL == true)
        #expect(LinkPolicy.url("javascript:alert(1)") == nil)
        #expect(LinkPolicy.url("vscode://open?x") == nil)
        #expect(LinkPolicy.url("not a url") == nil)
    }

    @Test func fileLinksNeverLaunchCode() {
        let open = { (t: UTType?) in LinkPolicy.fileAction(type: t, isExecutable: false, isDirectory: false, isPackage: false) }
        #expect(open(.mpeg4Movie) == .open)
        #expect(open(.png) == .open)
        #expect(open(.pdf) == .open)
        #expect(open(.shellScript) == .reveal)
        #expect(open(UTType(filenameExtension: "command")) == .reveal)
        #expect(open(.applicationBundle) == .reveal)
        #expect(open(.unixExecutable) == .reveal)
        #expect(open(UTType(filenameExtension: "pkg")) == .reveal)
        #expect(open(nil) == .reveal)
        #expect(LinkPolicy.fileAction(type: .plainText, isExecutable: true, isDirectory: false, isPackage: false) == .reveal)
        #expect(LinkPolicy.fileAction(type: .folder, isExecutable: false, isDirectory: true, isPackage: false) == .reveal)
    }
}
