import Foundation
import CCProtocol

public struct IndexSnapshot {
    public var sessions: [SessionInfo] = []
    public var targets: [String: GovernTarget] = [:]
    public var views: [GovernView] = []
    public var totals: Totals { Totals(rssBytes: sessions.reduce(0) { $0 + $1.rssBytes },
                                       cpuPercent: sessions.reduce(0) { $0 + $1.cpuPercent },
                                       count: sessions.count) }
    /// Sessions whose hibernated flag was cleared in this pass because they reappeared with a live pid.
    public var resumed: [String] = []
}

/// Merges `claude agents --json`, the process table and transcript mtimes into the store and a snapshot.
public final class SessionIndex {
    let store: SessionStore
    let runner: AgentsRunner
    let table: ProcessTable
    let time: TimeSource
    let transcripts: TranscriptProbe
    var lastEntries: [AgentEntry] = []
    private var prevCPU: [String: (cpuNs: UInt64, wallMs: Int64)] = [:]
    private var baseline: [Int32: UInt64] = [:]
    private var baselineAt: Int64?
    public var log: (String) -> Void = { _ in }

    public init(store: SessionStore, runner: AgentsRunner, table: ProcessTable, time: TimeSource, transcripts: TranscriptProbe) {
        self.store = store
        self.runner = runner
        self.table = table
        self.time = time
        self.transcripts = transcripts
    }

    /// Take a CPU baseline so a one-shot `status` can report CPU% from a second sample.
    public func primeCPU() {
        baselineAt = time.nowMs()
        baseline = Dictionary(table.snapshot().map { ($0.pid, $0.cpuNs) }, uniquingKeysWith: { a, _ in a })
    }

    /// Fresh `claude agents --json`. On failure the previous entries are reused so one flaky run does not blank the index.
    public func poll(focused: Set<String> = [], owned: Set<String> = []) -> IndexSnapshot {
        do {
            lastEntries = try runner.run()
        } catch {
            log("agents poll failed: \(error)")
        }
        return build(entries: lastEntries, focused: focused, owned: owned)
    }

    /// Re-measure using the cached agents entries (after a state change, without re-running `claude`).
    public func repoll(focused: Set<String> = [], owned: Set<String> = []) -> IndexSnapshot {
        build(entries: lastEntries, focused: focused, owned: owned)
    }

    /// Hook events and busy transitions raise lastActivity; it never goes backwards.
    public func noteActivity(sessionId: String, atMs: Int64) {
        guard SessionID.isValid(sessionId), let row = try? store.row(sessionId) else { return }
        if (row.lastActivity ?? 0) < atMs { try? store.setLastActivity(sessionId, atMs) }
    }

    private func build(entries: [AgentEntry], focused: Set<String>, owned: Set<String>) -> IndexSnapshot {
        let now = time.nowMs()
        let procs = table.snapshot()
        var byPid: [Int32: ProcessRecord] = [:]
        for r in procs { byPid[r.pid] = r }
        var snap = IndexSnapshot()
        var present: Set<String> = []

        for e in entries where SessionID.isValid(e.sessionId) && !present.contains(e.sessionId) {
            present.insert(e.sessionId)
            let id = e.sessionId
            let existing = (try? store.row(id)) ?? nil
            let state = e.state
            var row = existing ?? SessionRow(sessionId: id, cwd: e.cwd, kind: e.kind.rawValue, state: state.rawValue)
            row.cwd = e.cwd.isEmpty ? row.cwd : e.cwd
            row.name = e.name
            row.updatedAt = now

            var rss: UInt64 = 0, cpu = 0.0, children = 0
            var shell = false
            var info: SessionInfo

            let stalePid = e.kind == .interactive && e.pid.map { byPid[$0] == nil } ?? true
            if existing?.hibernated == true && stalePid {
                // Entry lingers after the tree was killed, or the process is gone: keep the hibernated row.
                info = Self.hibernatedInfo(row)
                snap.sessions.append(applyFlags(info, row: row, focused: focused, owned: owned))
                continue
            }
            if existing?.hibernated == true {
                row.hibernated = false
                row.hibernatedAt = nil
                snap.resumed.append(id)
            }

            row.kind = e.kind.rawValue
            row.state = state.rawValue

            if e.kind == .interactive, let pid = e.pid, let rec = byPid[pid] {
                if existing?.pid == pid, let st = existing?.pidStartTime {
                    row.pidStartTime = st // start time recorded at first sight; a mismatch later means pid reuse
                } else {
                    row.pidStartTime = rec.startTime
                }
                // Kernel state, not the stored flag: a row rebuilt after the session briefly left the index
                // (or after a daemon restart) must still know the tree is backgrounded so policy restores it.
                row.demoted = rec.background
                row.pid = pid
                if let tree = ProcessTree.stats(root: pid, table: procs) {
                    rss = tree.rssBytes
                    children = tree.childCount
                    shell = tree.hasShellDescendant
                    cpu = cpuPercent(id: id, cpuNs: tree.cpuNs, tree: tree.pids, now: now)
                    var times: [Int32: UInt64] = [:]
                    for p in tree.pids { times[p] = byPid[p]?.startTime }
                    times[pid] = row.pidStartTime
                    snap.targets[id] = GovernTarget(sessionId: id, cwd: row.cwd, rootPid: pid, pids: tree.pids,
                                                    recordedStartTimes: times, rssBytes: tree.rssBytes)
                }
            } else {
                row.pid = nil
                row.pidStartTime = nil
                row.demoted = false
            }

            var last = max(row.lastActivity ?? 0, transcripts.mtimeMs(sessionId: id) ?? 0)
            if state == .running { last = max(last, now) }
            row.lastActivity = last > 0 ? last : nil

            try? store.upsert(row)

            info = SessionInfo(sessionId: id, cwd: row.cwd, name: row.name, kind: e.kind == .interactive ? .interactive : .background,
                               state: state, pid: row.pid, rssBytes: rss, cpuPercent: cpu, childCount: children,
                               lastActivityMs: row.lastActivity)
            snap.sessions.append(applyFlags(info, row: row, focused: focused, owned: owned))
            snap.views.append(GovernView(sessionId: id, kind: info.kind, state: state, hasPid: row.pid != nil,
                                         pinned: row.pinned, demoted: row.demoted, focused: focused.contains(id),
                                         lastActivityMs: row.lastActivity, hasShellDescendant: shell))
        }

        // Rows no longer in the index: hibernated rows stay and are listed; others are dropped unless pinned.
        for row in (try? store.all()) ?? [] where !present.contains(row.sessionId) {
            if row.hibernated {
                snap.sessions.append(applyFlags(Self.hibernatedInfo(row), row: row, focused: focused, owned: owned))
            } else if !row.pinned {
                try? store.delete(row.sessionId)
            }
        }
        snap.sessions.sort { ($0.cwd, $0.sessionId) < ($1.cwd, $1.sessionId) }
        return snap
    }

    private func cpuPercent(id: String, cpuNs: UInt64, tree: [Int32], now: Int64) -> Double {
        defer { prevCPU[id] = (cpuNs, now) }
        if let p = prevCPU[id], now > p.wallMs, cpuNs >= p.cpuNs {
            return Double(cpuNs - p.cpuNs) / (Double(now - p.wallMs) * 1_000_000) * 100
        }
        if prevCPU[id] == nil, let at = baselineAt, now > at {
            let base = tree.reduce(UInt64(0)) { $0 + (baseline[$1] ?? 0) }
            if cpuNs >= base { return Double(cpuNs - base) / (Double(now - at) * 1_000_000) * 100 }
        }
        return 0
    }

    private static func hibernatedInfo(_ row: SessionRow) -> SessionInfo {
        SessionInfo(sessionId: row.sessionId, cwd: row.cwd, name: row.name, kind: .hibernated, state: .hibernated,
                    lastActivityMs: row.lastActivity, hibernatedAtMs: row.hibernatedAt)
    }

    private func applyFlags(_ i: SessionInfo, row: SessionRow, focused: Set<String>, owned: Set<String>) -> SessionInfo {
        var i = i
        i.pinned = row.pinned
        i.demoted = row.demoted
        i.focused = focused.contains(row.sessionId)
        i.ownedByApp = owned.contains(row.sessionId)
        return i
    }
}
