import Foundation
import Testing
import CCProtocol
@testable import CCGovCore

@Suite struct AgentsDecodeTests {
    @Test func decodesInteractiveAndBackgroundShapes() throws {
        let json = """
        [
         {"pid":123,"cwd":"/p/one","kind":"interactive","startedAt":1786396345723,"sessionId":"\(sidA)","name":"one","status":"busy","extra":1},
         {"id":"22222222","cwd":"/p/two","kind":"background","startedAt":1786396345999,"sessionId":"\(sidB)","name":"two","state":"blocked"},
         {"pid":9,"cwd":"/p/bad","kind":"interactive","sessionId":"not-a-uuid","status":"idle"}
        ]
        """
        let list = try AgentEntry.decodeList(Data(json.utf8))
        #expect(list.count == 2) // invalid session id dropped
        #expect(list[0].kind == .interactive && list[0].pid == 123 && list[0].state == .running)
        #expect(list[0].startedAt == 1786396345723 && list[0].name == "one")
        #expect(list[1].kind == .background && list[1].pid == nil && list[1].state == .blocked)
    }
}

@Suite struct TreeTests {
    @Test func aggregatesRootAndDescendantsOnly() {
        let table = [
            rec(10, 1, "claude", rss: 100, cpu: 5), rec(11, 10, "node", rss: 10, cpu: 1),
            rec(12, 11, "node", rss: 1, cpu: 2), rec(20, 1, "claude", rss: 999, cpu: 9), rec(21, 20, "node", rss: 999),
        ]
        let s = ProcessTree.stats(root: 10, table: table)
        #expect(s?.pids == [10, 11, 12])
        #expect(s?.rssBytes == 111)
        #expect(s?.cpuNs == 8)
        #expect(s?.childCount == 2)
        #expect(s?.hasShellDescendant == false)
        #expect(ProcessTree.stats(root: 77, table: table) == nil)
    }

    @Test func detectsShellDescendant() {
        let table = [rec(10, 1, "claude"), rec(11, 10, "node"), rec(12, 11, "zsh")]
        #expect(ProcessTree.stats(root: 10, table: table)?.hasShellDescendant == true)
    }
}

@Suite struct StoreTests {
    @Test func upsertRetainsHibernatedRowAndSurvivesReopen() throws {
        let path = NSTemporaryDirectory() + "ccgov-store-\(UUID().uuidString).db"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        do {
            let store = try SessionStore(path: path)
            try store.upsert(SessionRow(sessionId: sidA, cwd: "/p/a", name: "a", kind: "interactive", state: "idle", pid: 42, pidStartTime: 7))
            try store.upsert(SessionRow(sessionId: sidA, cwd: "/p/a2", name: "a", kind: "interactive", state: "running", pid: 42, pidStartTime: 7))
            try store.upsert(SessionRow(sessionId: sidB, cwd: "/p/b", kind: "interactive", state: "idle", pid: 43, pidStartTime: 8))
            try store.setPinned(sidB, true)
            try store.markHibernated(sidB, atMs: 5555)
            #expect(try store.all().count == 2)
            #expect(try store.row(sidA)?.cwd == "/p/a2") // upsert replaced, not duplicated
        }
        let reopened = try SessionStore(path: path)
        let b = try reopened.row(sidB)
        #expect(b?.hibernated == true && b?.hibernatedAt == 5555 && b?.pinned == true && b?.pid == nil)
        #expect(try reopened.row(sidA)?.state == "running")
    }

    @Test func indexKeepsHibernatedRowWhenSessionLeavesAgents() throws {
        let store = try SessionStore(path: ":memory:")
        try store.upsert(SessionRow(sessionId: sidA, cwd: "/p/a", kind: "interactive", state: "idle", pid: 42, pidStartTime: 1000))
        try store.markHibernated(sidA, atMs: 1)
        try store.upsert(SessionRow(sessionId: sidB, cwd: "/p/b", kind: "interactive", state: "idle", pid: 43, pidStartTime: 1000))
        let index = SessionIndex(store: store, runner: FakeRunner(entries: []), table: FakeTable(), time: FakeTime(), transcripts: FakeTranscripts())
        let snap = index.poll()
        #expect(snap.sessions.map(\.sessionId) == [sidA])
        #expect(snap.sessions.first?.state == .hibernated && snap.sessions.first?.kind == .hibernated)
        #expect(try store.row(sidB) == nil) // ordinary absent row dropped
        #expect(try store.row(sidA) != nil)
    }
}

@Suite struct GovernorTests {
    let policy = GovernPolicy(demoteAfterMs: 60_000, hibernateAfterMs: 30 * 60_000)
    let now: Int64 = 10_000_000_000

    @Test func hibernatesAtThresholdNotJustUnder() {
        let atThreshold = GovernView(sessionId: sidA, state: .idle, lastActivityMs: now - policy.hibernateAfterMs)
        let justUnder = GovernView(sessionId: sidB, state: .idle, lastActivityMs: now - policy.hibernateAfterMs + 1)
        let actions = Governor.decide(views: [atThreshold, justUnder], nowMs: now, policy: policy)
        #expect(actions.contains(.hibernate(sidA)))
        #expect(!actions.contains(.hibernate(sidB)))
        #expect(actions.contains(.demote(sidB))) // under hibernate threshold but past 60 s: demoted instead
    }

    @Test func skipsPinnedAndBusyAndNonInteractive() {
        let old = now - 10 * policy.hibernateAfterMs
        let views = [
            GovernView(sessionId: sidA, state: .idle, pinned: true, lastActivityMs: old),
            GovernView(sessionId: sidB, state: .running, lastActivityMs: old),
            GovernView(sessionId: "33333333-3333-4333-8333-333333333333", kind: .background, state: .blocked, hasPid: false, lastActivityMs: old),
        ]
        let actions = Governor.decide(views: views, nowMs: now, policy: policy)
        #expect(!actions.contains(.hibernate(sidA)))
        #expect(!actions.contains(.hibernate(sidB)))
        #expect(actions.allSatisfy { if case .hibernate = $0 { return false }; return true })
    }

    @Test func skipsSessionWithShellDescendantThroughIndex() throws {
        // Real path: process table -> index -> GovernView -> policy.
        let store = try SessionStore(path: ":memory:")
        let time = FakeTime()
        let old = time.now - 3_600_000
        let table = FakeTable([
            rec(500, 1, "claude"), rec(501, 500, "node"), rec(502, 501, "bash"),
            rec(600, 1, "claude"), rec(601, 600, "node"),
        ])
        let entries = [
            AgentEntry(pid: 500, cwd: "/p/a", kind: .interactive, sessionId: sidA, rawState: "idle"),
            AgentEntry(pid: 600, cwd: "/p/b", kind: .interactive, sessionId: sidB, rawState: "idle"),
        ]
        let index = SessionIndex(store: store, runner: FakeRunner(entries: entries), table: table, time: time,
                                 transcripts: FakeTranscripts(mtimes: [sidA: old, sidB: old]))
        let snap = index.poll()
        let actions = Governor.decide(views: snap.views, nowMs: time.now, policy: policy)
        #expect(!actions.contains(.hibernate(sidA)))
        #expect(actions.contains(.hibernate(sidB)))
    }

    @Test func hibernateTerminatesChildrenBeforeRootThenKillsSurvivors() {
        let table = FakeTable([rec(500, 1, "claude"), rec(501, 500, "node"), rec(502, 501, "node")])
        let sender = RecordingSender()
        // 502 exits on SIGTERM; 501 and 500 ignore it and only die on SIGKILL.
        sender.onKill = { pid, sig in
            if sig == SIGKILL || pid == 502 { table.records.removeAll { $0.pid == pid } }
        }
        let gate = SignalGate(sender: sender, table: table, selfPid: 99, allowPids: [500])
        let gov = ProcessGovernor(gate: gate, table: table, time: FakeTime())
        let out = gov.hibernate(target: target(root: 500, pids: [500, 501, 502]))
        #expect(sender.kills.map(\.pid) == [502, 501, 500, 501, 500])
        #expect(sender.kills.map(\.signal) == [SIGTERM, SIGTERM, SIGTERM, SIGKILL, SIGKILL])
        #expect(out.rootGone && out.survivors.isEmpty && out.killed == [501, 500])
    }
}

@Suite struct SignalGateTests {
    @Test func pidOutsideAllowlistIsNeverSignalled() {
        let table = FakeTable([rec(500, 1, "claude"), rec(600, 1, "claude")])
        let sender = RecordingSender()
        let gate = SignalGate(sender: sender, table: table, selfPid: 99, allowPids: [600])
        let outside = target(root: 500)
        #expect(!gate.kill(pid: 500, signal: SIGTERM, target: outside))
        #expect(!gate.setBackground(pid: 500, background: true, target: outside))
        #expect(!sender.touched)
        // Same gate, allowlisted root: proceeds (proves the refusal above is the allowlist, not a broken gate).
        #expect(gate.kill(pid: 600, signal: SIGTERM, target: target(root: 600)))
        #expect(sender.kills.map(\.pid) == [600])
    }

    @Test func pidWithChangedStartTimeIsNeverSignalled() {
        let table = FakeTable([rec(500, 1, "claude", start: 2000)]) // pid reused: started later than recorded 1000
        let sender = RecordingSender()
        let gate = SignalGate(sender: sender, table: table, selfPid: 99, allowPids: [500])
        #expect(!gate.kill(pid: 500, signal: SIGKILL, target: target(root: 500, start: 1000)))
        #expect(!gate.setBackground(pid: 500, background: true, target: target(root: 500, start: 1000)))
        #expect(!sender.touched)
        #expect(gate.kill(pid: 500, signal: SIGTERM, target: target(root: 500, start: 2000)))
    }

    @Test func refusesPidOneSelfNonClaudeRootAndOutOfScopeCwd() {
        let table = FakeTable([rec(1, 0, "claude"), rec(99, 1, "claude"), rec(500, 1, "node"), rec(700, 1, "claude")])
        let sender = RecordingSender()
        let gate = SignalGate(sender: sender, table: table, selfPid: 99, scopeCwdPrefix: "/tmp/ccterm-test")
        #expect(!gate.kill(pid: 1, signal: SIGTERM, target: target(root: 1, cwd: "/tmp/ccterm-test/x")))
        #expect(!gate.kill(pid: 99, signal: SIGTERM, target: target(root: 99, cwd: "/tmp/ccterm-test/x")))
        #expect(!gate.kill(pid: 500, signal: SIGTERM, target: target(root: 500, cwd: "/tmp/ccterm-test/x")))
        #expect(!gate.kill(pid: 700, signal: SIGTERM, target: target(root: 700, cwd: "/Users/someone/real-project")))
        #expect(!gate.kill(pid: 700, signal: SIGTERM, target: target(root: 700, cwd: "/tmp/ccterm-test-evil/x")))
        #expect(!sender.touched)
        #expect(gate.kill(pid: 700, signal: SIGTERM, target: target(root: 700, cwd: "/tmp/ccterm-test/x")))
    }

    @Test func rootIdentityAcceptsVersionNamedBinaryButNotOtherProcesses() {
        // The real binary runs as .../claude/versions/2.1.319, so its kernel process name is the version.
        let sender = RecordingSender()
        let ok = SignalGate(sender: sender, table: FakeTable([rec(500, 1, "2.1.319")]), selfPid: 99)
        #expect(ok.kill(pid: 500, signal: SIGTERM, target: target(root: 500)))
        for bad in ["node", "2.1.x", "..", "zsh"] {
            let gate = SignalGate(sender: sender, table: FakeTable([rec(501, 1, bad)]), selfPid: 99)
            #expect(!gate.kill(pid: 501, signal: SIGTERM, target: target(root: 501)))
        }
        #expect(sender.kills.map(\.pid) == [500])
    }

    @Test func refusesDescendantThatIsNotUnderRoot() {
        // 501 is recorded as a descendant of 500, but in the live table it now hangs off a different parent.
        let table = FakeTable([rec(500, 1, "claude"), rec(501, 1, "node")])
        let sender = RecordingSender()
        let gate = SignalGate(sender: sender, table: table, selfPid: 99)
        #expect(!gate.kill(pid: 501, signal: SIGTERM, target: target(root: 500, pids: [500, 501])))
        #expect(!sender.touched)
    }
}

@Suite struct DaemonReadOnlyTests {
    @Test func withoutGovernNothingIsSignalledOrDemoted() throws {
        let table = FakeTable([rec(500, 1, "claude")])
        let sender = RecordingSender()
        let store = try SessionStore(path: ":memory:")
        let daemon = Daemon(config: DaemonConfig(), store: store,
                            runner: FakeRunner(entries: [AgentEntry(pid: 500, cwd: "/p/a", kind: .interactive, sessionId: sidA, rawState: "idle")]),
                            table: table, sender: sender, time: FakeTime(), transcripts: FakeTranscripts(), log: { _ in })
        _ = daemon.runCycle()
        for cmd in [Command.demote, .restore, .hibernate] {
            let r = daemon.handle(Request(id: "1", cmd: cmd, sessionId: sidA), client: nil)
            #expect(!r.ok)
        }
        #expect(!sender.touched)
        #expect(daemon.handle(Request(id: "2", cmd: .hibernate, sessionId: "../../etc"), client: nil).ok == false)
    }
}

@Suite struct SocketTests {
    func echoServer() throws -> (SocketServer, String) {
        let path = tempSocketPath()
        let server = SocketServer(path: path, handler: { req, _ in Response(id: req.id, ok: true) })
        try server.start()
        return (server, path)
    }

    @Test func socketIs0600InA0700Directory() throws {
        let (server, path) = try echoServer()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        var st = stat()
        #expect(stat(path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect((st.st_mode & S_IFMT) == S_IFSOCK)
        var dst = stat()
        #expect(stat((path as NSString).deletingLastPathComponent, &dst) == 0)
        #expect(dst.st_mode & 0o777 == 0o700)
    }

    @Test func malformedLineGetsErrorAndConnectionStaysUsable() throws {
        let (server, path) = try echoServer()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let two = Data("{not json\n{\"id\":\"x1\",\"cmd\":\"list\"}\n".utf8)
        let both = SocketClient.rawExchange(path: path, send: two, lines: 2)?.split(separator: "\n").map(String.init) ?? []
        #expect(both.count == 2)
        #expect(both.first?.contains("\"ok\":false") == true)
        #expect(both.last?.contains("\"id\":\"x1\"") == true && both.last?.contains("\"ok\":true") == true)
        let ok = SocketClient.request(path: path, Request(id: "x2", cmd: .list))
        #expect(ok?.ok == true && ok?.id == "x2")
        let unknown = SocketClient.rawExchange(path: path, send: Data("{\"id\":\"u1\",\"cmd\":\"explode\"}\n".utf8))
        #expect(unknown?.contains("\"id\":\"u1\"") == true && unknown?.contains("\"ok\":false") == true)
    }

    @Test func oversizeLineIsRejectedAndNeverReachesHandler() throws {
        let path = tempSocketPath()
        var handled = 0
        let server = SocketServer(path: path, handler: { req, _ in handled += 1; return Response(id: req.id, ok: true) })
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        var big = Data("{\"id\":\"b\",\"cmd\":\"list\",\"sessionId\":\"".utf8)
        big.append(Data(repeating: 0x41, count: WireLine.maxBytes + 10))
        big.append(Data("\"}\n".utf8))
        let reply = SocketClient.rawExchange(path: path, send: big)
        #expect(reply?.contains("\"ok\":false") == true)
        #expect(handled == 0)
    }

    @Test func overlongPathIsRejected() {
        let long = "/tmp/" + String(repeating: "a", count: 120) + "/s.sock"
        let server = SocketServer(path: long, handler: { r, _ in Response(id: r.id, ok: true) })
        #expect(throws: SocketError.self) { try server.start() }
    }
}
