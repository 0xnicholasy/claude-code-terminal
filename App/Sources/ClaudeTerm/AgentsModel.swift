import CCProtocol
import Foundation

/// One entry of `claude agents --json`. Two shapes exist:
/// interactive `{pid, cwd, kind, startedAt, sessionId, name, status}` and
/// background `{id, cwd, kind, startedAt, sessionId, name, state}` (no pid).
/// Unknown fields are ignored and any field may be missing or mistyped.
struct AgentRecord: Decodable, Equatable, Sendable {
    var pid: Int32?
    var id: String?
    var cwd: String?
    var kind: String?
    var startedAt: Int64?
    var sessionId: String?
    var name: String?
    var status: String?
    var state: String?

    private enum CodingKeys: String, CodingKey {
        case pid, id, cwd, kind, startedAt, sessionId, name, status, state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try? c.decodeIfPresent(Int32.self, forKey: .pid)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        if let ms = try? c.decodeIfPresent(Int64.self, forKey: .startedAt) {
            startedAt = ms
        } else if let ms = try? c.decodeIfPresent(Double.self, forKey: .startedAt) {
            startedAt = Int64(ms)
        }
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
    }

    init(pid: Int32? = nil, id: String? = nil, cwd: String? = nil, kind: String? = nil, startedAt: Int64? = nil,
         sessionId: String? = nil, name: String? = nil, status: String? = nil, state: String? = nil) {
        self.pid = pid
        self.id = id
        self.cwd = cwd
        self.kind = kind
        self.startedAt = startedAt
        self.sessionId = sessionId
        self.name = name
        self.status = status
        self.state = state
    }

    /// Convert to the shared `SessionInfo`; RSS comes from the process table when a pid is known.
    func sessionInfo(table: ProcessTable?) -> SessionInfo {
        let isBackground = kind?.lowercased() == "background"
        let sid = sessionId ?? id ?? "unknown-\(pid.map(String.init) ?? "0")"
        var rss: UInt64 = 0
        var children = 0
        if let pid, let table {
            rss = table.treeRSSBytes(root: pid)
            children = table.descendants(of: pid).count
        }
        return SessionInfo(
            sessionId: sid,
            cwd: cwd ?? "",
            name: name,
            kind: isBackground ? .background : .interactive,
            state: SessionState(agentsRaw: status ?? state),
            pid: pid,
            rssBytes: rss,
            childCount: children,
            lastActivityMs: startedAt
        )
    }
}

enum AgentsDecoder {
    /// Throws when the payload is not a JSON array, so callers keep the previous list.
    static func decode(_ data: Data) throws -> [AgentRecord] {
        try JSONDecoder().decode([AgentRecord].self, from: data)
    }
}

/// Snapshot of `ps -axo pid=,ppid=,rss=` with process-tree helpers.
struct ProcessTable: Equatable, Sendable {
    private var rssKB: [Int32: UInt64] = [:]
    private var children: [Int32: [Int32]] = [:]

    init(psOutput: String) {
        for line in psOutput.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 3, let pid = Int32(f[0]), let ppid = Int32(f[1]), let rss = UInt64(f[2]) else { continue }
            rssKB[pid] = rss
            children[ppid, default: []].append(pid)
        }
    }

    func contains(_ pid: Int32) -> Bool { rssKB[pid] != nil }

    /// All transitive children of `root` (root excluded). Cycle-safe.
    func descendants(of root: Int32) -> [Int32] {
        var seen: Set<Int32> = [root]
        var out: [Int32] = []
        var stack = children[root] ?? []
        while let p = stack.popLast() {
            guard seen.insert(p).inserted else { continue }
            out.append(p)
            stack.append(contentsOf: children[p] ?? [])
        }
        return out
    }

    /// Resident bytes of `root` plus every descendant. 0 when `root` is not in the table.
    func treeRSSBytes(root: Int32) -> UInt64 {
        guard let own = rssKB[root] else { return 0 }
        let sum = descendants(of: root).reduce(own) { $0 + (rssKB[$1] ?? 0) }
        return sum * 1024
    }
}

struct ProjectGroup: Equatable, Identifiable {
    var id: String { path }
    var path: String
    var name: String
    var sessions: [SessionInfo]
    var rssBytes: UInt64 { sessions.reduce(0) { $0 + $1.rssBytes } }
}

enum SessionGrouping {
    /// Group by cwd (two projects with the same folder name stay separate). Sorted by name, then path.
    static func group(_ sessions: [SessionInfo]) -> [ProjectGroup] {
        let byPath = Dictionary(grouping: sessions, by: \.cwd)
        return byPath.map { path, list in
            ProjectGroup(
                path: path,
                name: path.isEmpty ? "Unknown" : (path as NSString).lastPathComponent,
                sessions: list.sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
            )
        }
        .sorted {
            let c = $0.name.localizedCaseInsensitiveCompare($1.name)
            return c == .orderedSame ? $0.path < $1.path : c == .orderedAscending
        }
    }

    static func displayName(_ s: SessionInfo) -> String {
        if let n = s.name, !n.isEmpty { return n }
        return String(s.sessionId.prefix(8))
    }
}
