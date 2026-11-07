import CCProtocol
import Darwin
import Foundation
import Testing
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
        let sections = SidebarLayout.sections(m.rows)
        guard case let .project(_, _, sessions)? = sections.first?.entries.first else {
            Issue.record("expected one project entry")
            return
        }
        #expect(sessions.count == 2)
    }
}
