import CCProtocol
import Darwin
import Foundation

/// Kernel facts about one process, read at a single moment. Start time plus pid identifies a
/// process uniquely, so a reused pid never matches an identity read earlier.
struct ProcIdentity: Equatable, Sendable {
    let uid: uid_t
    let startSec: UInt64
    let startUsec: UInt64
    let path: String
}

protocol ProcessControl: Sendable {
    func identity(_ pid: Int32) -> ProcIdentity?
    func signal(_ pid: Int32, _ sig: Int32) -> Bool
}

struct SystemProcessControl: ProcessControl {
    func identity(_ pid: Int32) -> ProcIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return ProcIdentity(uid: info.pbi_uid, startSec: info.pbi_start_tvsec,
                            startUsec: info.pbi_start_tvusec, path: String(cString: buf))
    }

    func signal(_ pid: Int32, _ sig: Int32) -> Bool { Darwin.kill(pid, sig) == 0 }
}

/// Stops a claude process running in another terminal so its session can be resumed here.
enum Takeover {
    enum Refusal: Error, Equatable {
        case noPid
        case protectedPid
        case gone
        case otherUser
        case notClaude(String)
        case signalFailed
        case didNotExit
    }

    /// The installer puts claude at `.../bin/claude` (a link) whose target is `.../claude/versions/<semver>`.
    static func isClaudeBinary(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == "claude" { return true }
        return path.contains("/claude/versions/") && name.allSatisfy { $0.isNumber || $0 == "." }
    }

    static func verify(pid: Int32?, control: ProcessControl,
                       selfPid: Int32 = getpid(), uid: uid_t = getuid()) -> Result<ProcIdentity, Refusal> {
        guard let pid else { return .failure(.noPid) }
        guard pid > 1, pid != selfPid else { return .failure(.protectedPid) }
        guard let id = control.identity(pid) else { return .failure(.gone) }
        guard id.uid == uid else { return .failure(.otherUser) }
        guard isClaudeBinary(id.path) else { return .failure(.notClaude(id.path)) }
        return .success(id)
    }

    /// SIGTERM the verified process, then wait until it has exited. Never escalates to SIGKILL:
    /// if claude does not exit, the session stays where it is and the user can retry.
    static func stop(pid: Int32?, control: ProcessControl, timeout: Duration = .seconds(8),
                     selfPid: Int32 = getpid(), uid: uid_t = getuid()) async -> Refusal? {
        let id: ProcIdentity
        switch verify(pid: pid, control: control, selfPid: selfPid, uid: uid) {
        case let .failure(r): return r
        case let .success(v): id = v
        }
        guard let pid else { return .noPid }
        // Re-read immediately before signalling so a pid reused since verify() is never hit.
        guard control.identity(pid) == id else { return .gone }
        guard control.signal(pid, SIGTERM) else { return .signalFailed }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if control.identity(pid) != id { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return control.identity(pid) != id ? nil : .didNotExit
    }

    static func message(_ r: Refusal) -> String {
        switch r {
        case .noPid: "No process id is known for this session, so it cannot be taken over."
        case .protectedPid: "Refused: that process id is protected."
        case .gone: "The process already exited. Open the session again to resume it here."
        case .otherUser: "Refused: the process belongs to another user."
        case let .notClaude(path): "Refused: process is not claude (\(path))."
        case .signalFailed: "Could not stop the other process."
        case .didNotExit: "The other claude did not exit within 8 s. Nothing was changed; try again."
        }
    }
}

/// Finds the claude process a pane started. Panes run `login -> bash -> claude --resume <id>` as
/// descendants of this app, so only the app's own process tree is searched, and the match is on the
/// session id in claude's argv. A process outside the tree is never returned.
enum PaneProcess {
    static func claudePid(sessionId: String, root: Int32 = getpid()) -> Int32? {
        guard SessionID.isValid(sessionId) else { return nil }
        let table = parents()
        return table.keys.sorted().first { pid in
            isDescendant(pid, of: root, parents: table)
                && argv(pid).contains(sessionId)
                && argv(pid).first.map { Takeover.isClaudeBinary($0) || $0.hasSuffix("/claude") } == true
        }
    }

    /// Walks the parent chain; bounded so a corrupt table cannot loop.
    static func isDescendant(_ pid: Int32, of root: Int32, parents: [Int32: Int32]) -> Bool {
        var cur = pid
        for _ in 0..<64 {
            guard let p = parents[cur], p > 1 else { return false }
            if p == root { return true }
            cur = p
        }
        return false
    }

    /// pid -> parent pid for every process. Uses sysctl, not proc_pidinfo: the pane's
    /// `/usr/bin/login` runs as root, and proc_pidinfo cannot read another user's process, which
    /// broke the parent chain (seen live 2026-11-07).
    private static func parents() -> [Int32: Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        size += size / 8 // room for processes started between the two calls
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }
        var out: [Int32: Int32] = [:]
        for p in procs.prefix(size / stride) where p.kp_proc.p_pid > 0 {
            out[p.kp_proc.p_pid] = p.kp_eproc.e_ppid
        }
        return out
    }

    /// argv via KERN_PROCARGS2: argc, exec path, padding, then argv strings.
    static func argv(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    static func parseProcArgs(_ buf: [UInt8]) -> [String] {
        guard buf.count > 4 else { return [] }
        let argc = Int(buf[0]) | Int(buf[1]) << 8 | Int(buf[2]) << 16 | Int(buf[3]) << 24
        var i = 4
        while i < buf.count, buf[i] != 0 { i += 1 } // exec path
        while i < buf.count, buf[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < argc, i < buf.count {
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
