import CCProtocol
import Foundation

/// One project folder in the sidebar, holding every session that runs or ran in it.
struct SidebarProject: Identifiable, Equatable {
    var path: String
    var name: String
    var sessions: [SessionInfo]
    /// True when at least one of its sessions has a pane in this window.
    var isOpen: Bool

    var id: String { "project:" + path }
    var waiting: Int { sessions.filter { $0.state == .blocked }.count }
    var liveBytes: UInt64 { sessions.filter { $0.state != .hibernated }.reduce(0) { $0 + $1.rssBytes } }
}

struct SidebarProjects: Equatable {
    /// Projects with a pane open, in pane order: the order Cmd-1 to Cmd-9 follow.
    var open: [SidebarProject]
    /// Every other project, by name.
    var other: [SidebarProject]

    var all: [SidebarProject] { open + other }
}

enum SidebarLayout {
    /// Project-first sidebar. Projects with an open pane come first, ordered by their first pane;
    /// the rest follow by name. Inside a project, sessions with a pane come first in pane order,
    /// then the others by name. State is never a sort key, so a row moves only when a pane opens
    /// or closes, and the Cmd-number badges read 1, 2, 3 from top to bottom.
    static func projects(_ rows: [SessionInfo], paneOrder: [String]) -> SidebarProjects {
        let rank = Dictionary(paneOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let built = Dictionary(grouping: rows, by: { projectKey($0.cwd) }).map { path, list in
            SidebarProject(path: path, name: projectName(path),
                           sessions: list.sorted { before($0, $1, rank: rank) },
                           isOpen: list.contains { rank[$0.sessionId] != nil })
        }
        func firstPane(_ p: SidebarProject) -> Int { p.sessions.compactMap { rank[$0.sessionId] }.min() ?? Int.max }
        let open = built.filter(\.isOpen).sorted { firstPane($0) < firstPane($1) }
        let other = built.filter { !$0.isOpen }.sorted {
            let c = $0.name.localizedCaseInsensitiveCompare($1.name)
            return c == .orderedSame ? $0.path < $1.path : c == .orderedAscending
        }
        return SidebarProjects(open: open, other: other)
    }

    /// Every session in the order the sidebar shows it.
    static func order(_ rows: [SessionInfo], paneOrder: [String]) -> [SessionInfo] {
        projects(rows, paneOrder: paneOrder).all.flatMap(\.sessions)
    }

    private static func before(_ a: SessionInfo, _ b: SessionInfo, rank: [String: Int]) -> Bool {
        switch (rank[a.sessionId], rank[b.sessionId]) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil):
            let c = SessionGrouping.displayName(a).localizedCaseInsensitiveCompare(SessionGrouping.displayName(b))
            return c == .orderedSame ? a.sessionId < b.sessionId : c == .orderedAscending
        }
    }

    /// The folder a session is grouped under: the parent repo for a `claude -w` worktree session,
    /// else its own folder.
    static func projectKey(_ cwd: String) -> String {
        Worktree.parentRepo(of: cwd) ?? cwd
    }

    static func projectName(_ path: String) -> String {
        path.isEmpty ? "Unknown" : (path as NSString).lastPathComponent
    }
}

/// Keeps a project's panes next to each other, so pane order (Cmd-1 to Cmd-9) matches the sidebar.
enum PaneOrder {
    /// Where a new pane in `cwd` goes: right after the last pane of the same project (a worktree
    /// counts as its parent repo, as in the sidebar), else at the end.
    static func insertionIndex(cwds: [String], cwd: String) -> Int {
        let key = SidebarLayout.projectKey(cwd)
        return cwds.lastIndex { SidebarLayout.projectKey($0) == key }.map { $0 + 1 } ?? cwds.count
    }

    /// Stable regroup for layouts saved before panes were kept together: each project's panes move
    /// up to its first pane; relative order is otherwise kept.
    static func grouped<T>(_ items: [T], key: (T) -> String) -> [T] {
        var firstSeen: [String: Int] = [:]
        for (i, item) in items.enumerated() where firstSeen[key(item)] == nil { firstSeen[key(item)] = i }
        return items.enumerated()
            .sorted { (firstSeen[key($0.element)] ?? 0, $0.offset) < (firstSeen[key($1.element)] ?? 0, $1.offset) }
            .map(\.element)
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

    /// "2026-11" -> "November 2026".
    static func monthTitle(_ key: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        guard let d = f.date(from: key) else { return key }
        return d.formatted(.dateTime.month(.wide).year())
    }

    /// "Sat 7 Nov, 10:00 to 15:00".
    static func blockTitle(_ start: Date, _ end: Date) -> String {
        start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ", "
            + start.formatted(date: .omitted, time: .shortened) + " to " + end.formatted(date: .omitted, time: .shortened)
    }

    /// Active block: burn rate, projected cost and minutes left. Past block: tokens.
    static func blockDetail(_ b: UsageBlock) -> String {
        var parts = [tokens(b.tokens) + " tokens"]
        if b.isActive {
            if let r = b.costPerHour { parts.append(dollars(r) + "/h") }
            if let p = b.projectedCost { parts.append("on pace for " + dollars(p)) }
            if let m = b.remainingMinutes { parts.append("\(m / 60)h \(m % 60)m left") }
        }
        return parts.joined(separator: " \u{00B7} ")
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
    static let newWorktree = shift + cmd + "T"
    static let closePane = shift + cmd + "W"
    static let nextPane = shift + cmd + "]"
    static let previousPane = shift + cmd + "["
    static let sessionsTab = control + cmd + "1"
    static let usageTab = control + cmd + "2"
    static let configTab = control + cmd + "3"
    static let toggleTab = shift + cmd + "U"
    static let nextSession = option + cmd + "\u{2193}"
    static let previousSession = option + cmd + "\u{2191}"
    static let toggleSidebar = control + cmd + "S"
    static let clipboard = shift + cmd + "V"
    static let replies = shift + cmd + "M"

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
