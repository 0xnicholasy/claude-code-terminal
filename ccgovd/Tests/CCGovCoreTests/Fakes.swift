import Foundation
import CCProtocol
@testable import CCGovCore

final class FakeTable: ProcessTable {
    var records: [ProcessRecord]
    init(_ records: [ProcessRecord] = []) { self.records = records }
    func snapshot() -> [ProcessRecord] { records }
}

final class RecordingSender: SignalSender {
    var kills: [(pid: Int32, signal: Int32)] = []
    var priorities: [(pid: Int32, background: Bool)] = []
    var bg: [Int32: Bool] = [:]
    var onKill: ((Int32, Int32) -> Void)?

    func kill(pid: Int32, signal: Int32) -> Bool {
        kills.append((pid, signal))
        onKill?(pid, signal)
        return true
    }
    func setBackground(pid: Int32, background: Bool) -> Bool {
        priorities.append((pid, background))
        bg[pid] = background
        return true
    }
    func isBackground(pid: Int32) -> Bool? { bg[pid] ?? false }
    var touched: Bool { !kills.isEmpty || !priorities.isEmpty }
}

final class FakeTime: TimeSource {
    var now: Int64
    init(_ now: Int64 = 1_000_000_000) { self.now = now }
    func nowMs() -> Int64 { now }
    func sleep(ms: Int) { now += Int64(ms) }
}

struct FakeRunner: AgentsRunner {
    var entries: [AgentEntry]
    func run() throws -> [AgentEntry] { entries }
}

struct FakeTranscripts: TranscriptProbe {
    var mtimes: [String: Int64] = [:]
    func mtimeMs(sessionId: String) -> Int64? { mtimes[sessionId] }
}

let sidA = "11111111-1111-4111-8111-111111111111"
let sidB = "22222222-2222-4222-8222-222222222222"

func rec(_ pid: Int32, _ ppid: Int32, _ comm: String, start: UInt64 = 1000, rss: UInt64 = 1 << 20, cpu: UInt64 = 0) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: ppid, startTime: start, comm: comm, rssBytes: rss, cpuNs: cpu)
}

func target(root: Int32 = 500, cwd: String = "/tmp/ccterm-test/a", pids: [Int32]? = nil, start: UInt64 = 1000) -> GovernTarget {
    let all = pids ?? [root]
    return GovernTarget(sessionId: sidA, cwd: cwd, rootPid: root, pids: all,
                        recordedStartTimes: Dictionary(uniqueKeysWithValues: all.map { ($0, start) }))
}

func tempSocketPath() -> String {
    // sockaddr_un paths are limited to 103 bytes, so avoid the long $TMPDIR.
    "/tmp/ccgov-\(UInt32.random(in: 0..<UInt32.max))/s.sock"
}
