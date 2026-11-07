import Foundation
import Darwin

/// The only code that may call kill(2) or setpriority(2). Everything goes through `SignalGate`.
public protocol SignalSender {
    func kill(pid: Int32, signal: Int32) -> Bool
    func setBackground(pid: Int32, background: Bool) -> Bool
    /// Nil when the state cannot be read.
    func isBackground(pid: Int32) -> Bool?
}

public struct SystemSignalSender: SignalSender {
    public init() {}

    public func kill(pid: Int32, signal: Int32) -> Bool {
        Darwin.kill(pid, signal) == 0
    }

    public func setBackground(pid: Int32, background: Bool) -> Bool {
        setpriority(PRIO_DARWIN_PROCESS, id_t(pid), background ? PRIO_DARWIN_BG : 0) == 0
    }

    public func isBackground(pid: Int32) -> Bool? {
        errno = 0
        let v = getpriority(PRIO_DARWIN_PROCESS, id_t(pid))
        if v == -1 && errno != 0 { return nil }
        return v != 0
    }
}

/// A live interactive session as seen in one metrics pass: its root pid and the start time of every pid in its tree.
public struct GovernTarget: Equatable {
    public var sessionId: String
    public var cwd: String
    public var rootPid: Int32
    /// Root first, then descendants breadth-first.
    public var pids: [Int32]
    /// Root: start time recorded at first sight of the session. Descendants: start time in the current pass.
    public var recordedStartTimes: [Int32: UInt64]
    public var rssBytes: UInt64

    public init(sessionId: String, cwd: String, rootPid: Int32, pids: [Int32],
                recordedStartTimes: [Int32: UInt64], rssBytes: UInt64 = 0) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.rootPid = rootPid
        self.pids = pids
        self.recordedStartTimes = recordedStartTimes
        self.rssBytes = rssBytes
    }
}

public enum GateDecision: Equatable {
    case allow
    case refuse(String)
}

public final class SignalGate {
    public let sender: SignalSender
    public let table: ProcessTable
    public let selfPid: Int32
    /// Test mode: roots the daemon may govern (descendants of these are allowed). Nil = no allowlist.
    public let allowPids: Set<Int32>?
    public let scopeCwdPrefix: String?
    public let rootComm: String
    public var log: (String) -> Void

    public init(sender: SignalSender, table: ProcessTable, selfPid: Int32 = getpid(),
                allowPids: Set<Int32>? = nil, scopeCwdPrefix: String? = nil,
                rootComm: String = "claude", log: @escaping (String) -> Void = { _ in }) {
        self.sender = sender
        self.table = table
        self.selfPid = selfPid
        self.allowPids = allowPids
        self.scopeCwdPrefix = scopeCwdPrefix
        self.rootComm = rootComm
        self.log = log
    }

    private static func canonical(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func cwdInScope(_ cwd: String, prefix: String) -> Bool {
        let c = canonical(cwd), p = canonical(prefix)
        return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
    }

    /// Static scope only (allowlist root + cwd prefix). Lets the policy skip out-of-scope sessions silently
    /// instead of asking the gate to refuse every pid of every foreign session on every cycle.
    public func inScope(_ target: GovernTarget) -> Bool {
        if let allow = allowPids, !allow.contains(target.rootPid) { return false }
        if let prefix = scopeCwdPrefix, !Self.cwdInScope(target.cwd, prefix: prefix) { return false }
        return true
    }

    public func check(pid: Int32, target: GovernTarget, current: [ProcessRecord]) -> GateDecision {
        guard pid > 1 else { return .refuse("pid \(pid) <= 1") }
        guard pid != selfPid else { return .refuse("pid is the daemon itself") }
        guard let recorded = target.recordedStartTimes[pid], target.pids.contains(pid) else {
            return .refuse("pid \(pid) is not in session \(target.sessionId) tree")
        }
        if let allow = allowPids, !allow.contains(target.rootPid) {
            return .refuse("pid \(pid): root \(target.rootPid) not in test allowlist")
        }
        if let prefix = scopeCwdPrefix, !Self.cwdInScope(target.cwd, prefix: prefix) {
            return .refuse("pid \(pid): cwd \(target.cwd) outside scope prefix")
        }
        var byPid: [Int32: ProcessRecord] = [:]
        for r in current { byPid[r.pid] = r }
        guard let now = byPid[pid] else { return .refuse("pid \(pid) no longer exists") }
        guard now.startTime == recorded else { return .refuse("pid \(pid) start time changed (pid reused)") }
        if pid == target.rootPid {
            guard now.comm == rootComm else { return .refuse("root pid \(pid) comm '\(now.comm)' != '\(rootComm)'") }
        } else {
            // Descendant: its parent chain must reach the session root in the live table.
            var cur = now, hops = 0, reached = false
            while hops < 64, let parent = byPid[cur.ppid] {
                if parent.pid == target.rootPid { reached = true; break }
                cur = parent
                hops += 1
            }
            guard reached else { return .refuse("pid \(pid) is not a descendant of root \(target.rootPid)") }
        }
        return .allow
    }

    @discardableResult
    public func kill(pid: Int32, signal: Int32, target: GovernTarget) -> Bool {
        if case .refuse(let why) = check(pid: pid, target: target, current: table.snapshot()) {
            log("gate refused kill(\(pid), \(signal)): \(why)")
            return false
        }
        return sender.kill(pid: pid, signal: signal)
    }

    @discardableResult
    public func setBackground(pid: Int32, background: Bool, target: GovernTarget) -> Bool {
        if case .refuse(let why) = check(pid: pid, target: target, current: table.snapshot()) {
            log("gate refused setpriority(\(pid), bg=\(background)): \(why)")
            return false
        }
        return sender.setBackground(pid: pid, background: background)
    }
}

public struct PriorityOutcome: Equatable {
    public var results: [(pid: Int32, applied: Bool, verified: Bool)]
    public var allVerified: Bool { !results.isEmpty && results.allSatisfy { $0.verified } }
    public static func == (a: PriorityOutcome, b: PriorityOutcome) -> Bool {
        a.results.count == b.results.count && zip(a.results, b.results).allSatisfy { $0 == $1 }
    }
}

public struct HibernateOutcome: Equatable {
    public var terminated: [Int32]
    public var killed: [Int32]
    public var survivors: [Int32]
    public var rssFreedBytes: UInt64
    public var rootGone: Bool
}

/// Demote/restore and hibernate execution. Every effect is routed through the gate.
public final class ProcessGovernor {
    let gate: SignalGate
    let table: ProcessTable
    let time: TimeSource
    var termWaitMs = 5000
    var pollMs = 200

    public init(gate: SignalGate, table: ProcessTable, time: TimeSource) {
        self.gate = gate
        self.table = table
        self.time = time
    }

    public func setBackground(_ background: Bool, target: GovernTarget) -> PriorityOutcome {
        var results: [(pid: Int32, applied: Bool, verified: Bool)] = []
        for pid in target.pids {
            let applied = gate.setBackground(pid: pid, background: background, target: target)
            let verified = applied && gate.sender.isBackground(pid: pid) == background
            results.append((pid, applied, verified))
        }
        return PriorityOutcome(results: results)
    }

    private func alive(_ pids: [Int32], target: GovernTarget) -> [Int32] {
        let current = table.snapshot()
        var byPid: [Int32: ProcessRecord] = [:]
        for r in current { byPid[r.pid] = r }
        return pids.filter { byPid[$0]?.startTime == target.recordedStartTimes[$0] }
    }

    /// SIGTERM children first then the root, wait, SIGKILL survivors that still pass the gate.
    public func hibernate(target: GovernTarget) -> HibernateOutcome {
        let current = table.snapshot()
        var rss: [Int32: UInt64] = [:]
        for r in current { rss[r.pid] = r.rssBytes }
        let order = Array(target.pids.reversed()) // deepest first, root last
        var terminated: [Int32] = []
        for pid in order where gate.kill(pid: pid, signal: SIGTERM, target: target) { terminated.append(pid) }

        var waited = 0
        var left = alive(terminated, target: target)
        while !left.isEmpty && waited < termWaitMs {
            time.sleep(ms: pollMs)
            waited += pollMs
            left = alive(terminated, target: target)
        }
        var killed: [Int32] = []
        for pid in left where gate.kill(pid: pid, signal: SIGKILL, target: target) { killed.append(pid) }
        if !killed.isEmpty {
            time.sleep(ms: pollMs)
            left = alive(left, target: target)
        }
        let gone = Set(terminated).subtracting(left)
        let freed = gone.reduce(UInt64(0)) { $0 + (rss[$1] ?? 0) }
        return HibernateOutcome(terminated: terminated, killed: killed, survivors: left,
                                rssFreedBytes: freed, rootGone: gone.contains(target.rootPid))
    }
}
