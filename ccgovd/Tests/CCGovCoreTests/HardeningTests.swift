import Foundation
import Testing
import CCProtocol
@testable import CCGovCore

/// Regression tests for review findings fixed on 2026-11-07.
@Suite struct HardeningTests {
    @Test func sigkillReachesSurvivorReparentedToLaunchdButSigtermDoesNot() {
        // 501 was recorded in 500's tree; claude (500) exited on SIGTERM, so 501 now hangs off launchd.
        let table = FakeTable([rec(501, 1, "node")])
        let sender = RecordingSender()
        let gate = SignalGate(sender: sender, table: table, selfPid: 99)
        let t = target(root: 500, pids: [500, 501])
        #expect(!gate.kill(pid: 501, signal: SIGTERM, target: t))
        #expect(gate.kill(pid: 501, signal: SIGKILL, target: t))
        #expect(sender.kills.map(\.signal) == [SIGKILL])
        // Same pid reused by another process (new start time): even SIGKILL is refused.
        let reused = SignalGate(sender: RecordingSender(), table: FakeTable([rec(501, 1, "node", start: 9999)]), selfPid: 99)
        #expect(!reused.kill(pid: 501, signal: SIGKILL, target: t))
    }

    @Test func processOwnedByAnotherUidIsNeverSignalled() {
        var other = rec(500, 1, "claude")
        other.uid = getuid() &+ 1
        let sender = RecordingSender()
        let gate = SignalGate(sender: sender, table: FakeTable([other]), selfPid: 99)
        #expect(!gate.kill(pid: 500, signal: SIGTERM, target: target(root: 500)))
        #expect(!gate.setBackground(pid: 500, background: true, target: target(root: 500)))
        #expect(!sender.touched)
    }

    @Test func demotedFollowsKernelStateWhenRowIsRebuilt() throws {
        // A backgrounded session drops out of one agents poll (row deleted), then returns.
        let store = try SessionStore(path: ":memory:")
        var root = rec(500, 1, "claude")
        root.background = true
        let entry = AgentEntry(pid: 500, cwd: "/p/a", kind: .interactive, sessionId: sidA, rawState: "busy")
        let runner = FakeRunner(entries: [])
        let index = SessionIndex(store: store, runner: runner, table: FakeTable([root]), time: FakeTime(), transcripts: FakeTranscripts())
        _ = index.poll()
        #expect(try store.row(sidA) == nil)
        let back = SessionIndex(store: store, runner: FakeRunner(entries: [entry]), table: FakeTable([root]), time: FakeTime(), transcripts: FakeTranscripts())
        let snap = back.poll()
        #expect(snap.views.first?.demoted == true)
        // Busy + demoted: the policy restores it (it would not if the flag had been reset to false).
        let actions = Governor.decide(views: snap.views, nowMs: FakeTime().now,
                                      policy: GovernPolicy(demoteAfterMs: 60_000, hibernateAfterMs: 30 * 60_000))
        #expect(actions.contains(.restore(sidA)))
    }

    @Test func descendantOfReusedRootPidIsNeverSignalled() {
        // Root pid 500 was reused by a new process (start 2000); 501 matches the recorded start time and hangs
        // off the new 500. The parent chain reaches pid 500, but the root is no longer the recorded claude.
        let table = FakeTable([rec(500, 1, "claude", start: 2000), rec(501, 500, "node")])
        let sender = RecordingSender()
        let gate = SignalGate(sender: sender, table: table, selfPid: 99)
        let t = target(root: 500, pids: [500, 501])
        #expect(!gate.kill(pid: 501, signal: SIGTERM, target: t))
        #expect(!gate.setBackground(pid: 501, background: true, target: t))
        #expect(!sender.touched)
        // Control: with the recorded root alive, the same descendant is allowed.
        let ok = SignalGate(sender: RecordingSender(), table: FakeTable([rec(500, 1, "claude"), rec(501, 500, "node")]), selfPid: 99)
        #expect(ok.kill(pid: 501, signal: SIGTERM, target: t))
    }

    @Test func hibernateRefusesWhenAnUntrackedChildAppeared() {
        // 503 (a shell) started after the tree was indexed; killing claude would orphan it.
        let table = FakeTable([rec(500, 1, "claude"), rec(501, 500, "node"), rec(503, 500, "zsh")])
        let sender = RecordingSender()
        let gov = ProcessGovernor(gate: SignalGate(sender: sender, table: table, selfPid: 99), table: table, time: FakeTime())
        let out = gov.hibernate(target: target(root: 500, pids: [500, 501]))
        #expect(out.refused != nil && !out.complete)
        #expect(!sender.touched)
    }

    @Test func hibernateIsIncompleteWhenATrackedChildSurvives() {
        // The root dies on SIGTERM; child 501 is owned by another uid, so the gate refuses it and it keeps running.
        var foreign = rec(501, 500, "node")
        foreign.uid = getuid() &+ 1
        let table = FakeTable([rec(500, 1, "claude"), foreign])
        let sender = RecordingSender()
        sender.onKill = { pid, _ in table.records.removeAll { $0.pid == pid } }
        let gov = ProcessGovernor(gate: SignalGate(sender: sender, table: table, selfPid: 99), table: table, time: FakeTime())
        let out = gov.hibernate(target: target(root: 500, pids: [500, 501]))
        #expect(out.rootGone)
        #expect(out.survivors == [501] && !out.complete)
    }

    @Test func nonFiniteOrHugeDurationsAreRejected() {
        for args in [["--idle-seconds", "inf"], ["--idle-seconds", "1e300"], ["--idle-minutes", "nan"], ["--interval", "inf"]] {
            #expect(throws: CLIError.self) { _ = try CLI.config(from: CLI.parse(args), environment: [:]) }
        }
        #expect(throws: Never.self) { _ = try CLI.config(from: CLI.parse(["--idle-seconds", "5"]), environment: [:]) }
    }
}
