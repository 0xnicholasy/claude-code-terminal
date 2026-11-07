import Foundation
import Darwin

public struct ProcessRecord: Equatable {
    public var pid: Int32
    public var ppid: Int32
    /// Process start time in microseconds since the epoch (pbi_start_tvsec/tvusec). Identity key against pid reuse.
    public var startTime: UInt64
    public var comm: String
    public var rssBytes: UInt64
    /// User + system CPU time in nanoseconds.
    public var cpuNs: UInt64
    /// Real uid of the process owner. The gate only signals processes owned by the daemon's uid.
    public var uid: uid_t
    /// Kernel PRIO_DARWIN_BG state (PROC_FLAG_DARWINBG / EXT_DARWINBG), the source of truth for "demoted".
    public var background: Bool

    public init(pid: Int32, ppid: Int32, startTime: UInt64, comm: String, rssBytes: UInt64 = 0, cpuNs: UInt64 = 0,
                uid: uid_t = getuid(), background: Bool = false) {
        self.pid = pid
        self.ppid = ppid
        self.startTime = startTime
        self.comm = comm
        self.rssBytes = rssBytes
        self.cpuNs = cpuNs
        self.uid = uid
        self.background = background
    }
}

public protocol ProcessTable {
    func snapshot() -> [ProcessRecord]
}

public protocol TimeSource {
    func nowMs() -> Int64
    func sleep(ms: Int)
}

public struct SystemTime: TimeSource {
    public init() {}
    public func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    public func sleep(ms: Int) { usleep(UInt32(ms) * 1000) }
}

/// proc_listallpids + proc_pidinfo (PROC_PIDTBSDINFO, PROC_PIDTASKINFO). Processes we cannot inspect are skipped.
public struct DarwinProcessTable: ProcessTable {
    public init() {}

    public func snapshot() -> [ProcessRecord] {
        let hint = proc_listallpids(nil, 0)
        guard hint > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(hint) + 256)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }

        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let numer = UInt64(tb.numer), denom = UInt64(max(tb.denom, 1))

        var out: [ProcessRecord] = []
        out.reserveCapacity(Int(got))
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            if bsd.pbi_status == 5 { continue } // SZOMB
            var ti = proc_taskinfo()
            let haveTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, taskSize) == taskSize
            let rss = haveTask ? ti.pti_resident_size : 0
            let ticks = haveTask ? ti.pti_total_user &+ ti.pti_total_system : 0
            let cpuNs = ticks / denom * numer + (ticks % denom) * numer / denom
            let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
            var name = withUnsafePointer(to: &bsd.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            if name.isEmpty {
                name = withUnsafePointer(to: &bsd.pbi_comm) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
                }
            }
            let bgFlags: UInt32 = 0x8000 | 0x10000 // PROC_FLAG_DARWINBG | PROC_FLAG_EXT_DARWINBG
            out.append(ProcessRecord(pid: pid, ppid: Int32(bsd.pbi_ppid), startTime: start,
                                     comm: name, rssBytes: rss, cpuNs: cpuNs,
                                     uid: bsd.pbi_ruid, background: bsd.pbi_flags & bgFlags != 0))
        }
        return out
    }
}

public struct TreeStats: Equatable {
    /// Root first, then descendants breadth-first.
    public var pids: [Int32]
    public var rssBytes: UInt64
    public var cpuNs: UInt64
    public var hasShellDescendant: Bool
    public var childCount: Int { max(pids.count - 1, 0) }
}

public enum ProcessTree {
    public static let shellComms: Set<String> = ["sh", "bash", "zsh", "fish", "dash"]

    /// Root plus all descendants (cycle-safe). Nil when the root is not in the table.
    public static func stats(root: Int32, table: [ProcessRecord]) -> TreeStats? {
        var byPid: [Int32: ProcessRecord] = [:]
        var children: [Int32: [Int32]] = [:]
        for r in table {
            byPid[r.pid] = r
            children[r.ppid, default: []].append(r.pid)
        }
        guard byPid[root] != nil else { return nil }
        var order: [Int32] = [root]
        var seen: Set<Int32> = [root]
        var i = 0
        while i < order.count {
            for c in (children[order[i]] ?? []).sorted() where !seen.contains(c) && c != root {
                seen.insert(c)
                order.append(c)
            }
            i += 1
        }
        var rss: UInt64 = 0, cpu: UInt64 = 0, shell = false
        for pid in order {
            guard let r = byPid[pid] else { continue }
            rss += r.rssBytes
            cpu += r.cpuNs
            if pid != root, shellComms.contains(r.comm.hasPrefix("-") ? String(r.comm.dropFirst()) : r.comm) { shell = true }
        }
        return TreeStats(pids: order, rssBytes: rss, cpuNs: cpu, hasShellDescendant: shell)
    }
}
