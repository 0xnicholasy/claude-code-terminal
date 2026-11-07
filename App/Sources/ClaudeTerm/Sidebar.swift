import CCProtocol
import Foundation

/// Sidebar sections, ordered by what the user can do with a session (docs/design.md).
enum SidebarSectionKind: String, CaseIterable, Identifiable {
    case needsYou = "Needs you"
    case openHere = "Open here"
    case elsewhere = "Elsewhere"
    case asleep = "Asleep"

    var id: String { rawValue }

    static func of(_ s: SessionInfo) -> SidebarSectionKind {
        if s.state == .blocked { return .needsYou }
        if s.ownedByApp { return .openHere }
        if s.state == .hibernated || s.kind == .hibernated { return .asleep }
        return .elsewhere
    }
}

/// One sidebar line: a single session, or several sessions of the same project collapsed into one row.
enum SidebarEntry: Identifiable, Equatable {
    case session(SessionInfo)
    case project(path: String, name: String, sessions: [SessionInfo])

    var id: String {
        switch self {
        case let .session(s): s.sessionId
        case let .project(path, _, _): "project:" + path
        }
    }
}

struct SidebarSection: Identifiable, Equatable {
    var kind: SidebarSectionKind
    var entries: [SidebarEntry]
    var id: String { kind.id }
}

enum SidebarLayout {
    /// Sections in fixed order, empty ones dropped. Within a section, sessions sharing a project folder
    /// collapse into one project entry; entries sort by name.
    static func sections(_ rows: [SessionInfo]) -> [SidebarSection] {
        let bySection = Dictionary(grouping: rows, by: SidebarSectionKind.of)
        return SidebarSectionKind.allCases.compactMap { kind in
            guard let list = bySection[kind], !list.isEmpty else { return nil }
            let byPath = Dictionary(grouping: list, by: \.cwd)
            var entries: [SidebarEntry] = byPath.map { path, sessions in
                if sessions.count == 1 { return .session(sessions[0]) }
                return .project(path: path, name: projectName(path), sessions: sortByName(sessions))
            }
            entries.sort { sortKey($0).localizedCaseInsensitiveCompare(sortKey($1)) == .orderedAscending }
            return SidebarSection(kind: kind, entries: entries)
        }
    }

    /// Project shown next to the name only when it adds information.
    static func secondaryText(_ s: SessionInfo) -> String? {
        let project = projectName(s.cwd)
        let name = SessionGrouping.displayName(s)
        guard !s.cwd.isEmpty, !name.lowercased().hasPrefix(project.lowercased()) else { return nil }
        return project
    }

    /// Bar length for a row, relative to the largest live session (0...1).
    static func memoryFraction(_ s: SessionInfo, maxBytes: UInt64) -> Double {
        guard maxBytes > 0, s.state != .hibernated else { return 0 }
        return min(1, Double(s.rssBytes) / Double(maxBytes))
    }

    static func projectName(_ path: String) -> String {
        path.isEmpty ? "Unknown" : (path as NSString).lastPathComponent
    }

    private static func sortByName(_ list: [SessionInfo]) -> [SessionInfo] {
        list.sorted { SessionGrouping.displayName($0).localizedCaseInsensitiveCompare(SessionGrouping.displayName($1)) == .orderedAscending }
    }

    private static func sortKey(_ e: SidebarEntry) -> String {
        switch e {
        case let .session(s): SessionGrouping.displayName(s)
        case let .project(_, name, _): name
        }
    }
}

/// Toolbar numbers: live memory across all sessions, how many are asleep, memory freed by hibernation.
struct MemorySummary: Equatable {
    var liveBytes: UInt64
    var asleep: Int
    var freedBytes: UInt64

    init(liveBytes: UInt64, asleep: Int, freedBytes: UInt64) {
        self.liveBytes = liveBytes
        self.asleep = asleep
        self.freedBytes = freedBytes
    }

    init(rows: [SessionInfo], freedBytes: UInt64) {
        liveBytes = rows.filter { $0.state != .hibernated }.reduce(0) { $0 + $1.rssBytes }
        asleep = rows.filter { $0.state == .hibernated }.count
        self.freedBytes = freedBytes
    }
}

/// Counts memory freed by hibernation since app launch: when a session seen live with some RSS shows up
/// hibernated (or vanishes from a source that later reports it hibernated), its last live RSS is added once.
struct FreedTracker: Equatable {
    private(set) var freedBytes: UInt64 = 0
    private var lastLive: [String: UInt64] = [:]

    mutating func update(_ sessions: [SessionInfo]) {
        for s in sessions {
            if s.state == .hibernated {
                if let bytes = lastLive.removeValue(forKey: s.sessionId) { freedBytes += bytes }
            } else if s.rssBytes > 0 {
                lastLive[s.sessionId] = s.rssBytes
            }
        }
    }
}

enum Recents {
    /// Most recently active sessions that can be opened here (not background), newest first.
    static func top(_ rows: [SessionInfo], limit: Int = 3) -> [SessionInfo] {
        rows.filter { $0.kind != .background }
            .sorted { ($0.lastActivityMs ?? 0) > ($1.lastActivityMs ?? 0) }
            .prefix(limit)
            .map { $0 }
    }
}

enum Formatting {
    static func bytes(_ b: UInt64) -> String {
        let mb = Double(b) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    /// "45 m", "2 h", "3 d" since `ms`; nil when unknown.
    static func elapsed(sinceMs ms: Int64?, nowMs: Int64) -> String? {
        guard let ms, nowMs > ms else { return nil }
        let minutes = (nowMs - ms) / 60_000
        if minutes < 60 { return "\(max(1, minutes)) m" }
        if minutes < 60 * 24 { return "\(minutes / 60) h" }
        return "\(minutes / (60 * 24)) d"
    }

    static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
