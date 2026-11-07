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
