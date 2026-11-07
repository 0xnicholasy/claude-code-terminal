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
    /// Every session in the order the sidebar shows it, project children in place.
    static func order(_ rows: [SessionInfo]) -> [SessionInfo] {
        sections(rows).flatMap { section in
            section.entries.flatMap { entry -> [SessionInfo] in
                switch entry {
                case let .session(s): [s]
                case let .project(_, _, sessions): sessions
                }
            }
        }
    }

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

    static func dollars(_ v: Double) -> String { v.formatted(.currency(code: "USD")) }

    /// 12_345 -> "12.3K", 2_631_338 -> "2.6M".
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000_000 { return String(format: "%.1fB", d / 1_000_000_000) }
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1000 { return String(format: "%.1fK", d / 1000) }
        return "\(n)"
    }

    /// "claude-opus-5-5" -> "Opus 5.5". Unknown shapes pass through unchanged.
    static func modelName(_ id: String) -> String {
        let parts = id.split(separator: "-")
        guard parts.count >= 3, parts[0] == "claude" else { return id }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        let version = parts.dropFirst(2).prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }

    /// "2026-11-07" -> "Sat, 7 Nov" in the user's locale.
    static func dayTitle(_ key: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return key }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Keyboard shortcut labels shown in hover hints and sidebar badges. They mirror the menu commands
/// in ClaudeTermApp.swift; symbols are written as escapes so the source stays ASCII.
enum Shortcuts {
    static let cmd = "\u{2318}", shift = "\u{21E7}", option = "\u{2325}", control = "\u{2303}"

    static let newSession = cmd + "N"
    static let newInProject = shift + cmd + "N"
    static let closePane = shift + cmd + "W"
    static let nextPane = shift + cmd + "]"
    static let previousPane = shift + cmd + "["
    static let sessionsTab = control + cmd + "1"
    static let usageTab = control + cmd + "2"
    static let toggleTab = shift + cmd + "U"
    static let nextSession = option + cmd + "\u{2193}"
    static let previousSession = option + cmd + "\u{2191}"
    static let toggleSidebar = control + cmd + "S"

    /// Cmd-1 to Cmd-8 select panes 1 to 8; Cmd-9 selects the last pane.
    static func pane(index: Int, count: Int) -> String? {
        guard index >= 0, index < count else { return nil }
        if index < 8 { return cmd + "\(index + 1)" }
        return index == count - 1 ? cmd + "9" : nil
    }

    /// "New Session  (Cmd-N symbol)": the tooltip form used across the app.
    static func hint(_ action: String, _ key: String?) -> String {
        guard let key else { return action }
        return "\(action)  \(key)"
    }
}
