import Foundation

/// Normalised session state shown in the UI and used by the governor.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    case running
    case idle
    case blocked
    case hibernated
    case unknown

    /// Map the raw `status` (interactive) or `state` (background) field of `claude agents --json`.
    public init(agentsRaw raw: String?) {
        switch raw?.lowercased() {
        case "busy", "running", "working": self = .running
        case "idle": self = .idle
        case "blocked", "waiting", "needs_input": self = .blocked
        case "hibernated": self = .hibernated
        default: self = .unknown
        }
    }
}

public enum SessionKind: String, Codable, Sendable {
    case interactive
    case background
    case hibernated
}

public struct SessionInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    public var cwd: String
    public var name: String?
    public var kind: SessionKind
    public var state: SessionState
    public var pid: Int32?
    /// Resident bytes of the claude process plus all descendants.
    public var rssBytes: UInt64
    public var cpuPercent: Double
    public var childCount: Int
    public var pinned: Bool
    public var demoted: Bool
    public var focused: Bool
    public var lastActivityMs: Int64?
    public var hibernatedAtMs: Int64?
    public var ownedByApp: Bool

    public init(
        sessionId: String, cwd: String, name: String? = nil, kind: SessionKind, state: SessionState,
        pid: Int32? = nil, rssBytes: UInt64 = 0, cpuPercent: Double = 0, childCount: Int = 0,
        pinned: Bool = false, demoted: Bool = false, focused: Bool = false,
        lastActivityMs: Int64? = nil, hibernatedAtMs: Int64? = nil, ownedByApp: Bool = false
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.kind = kind
        self.state = state
        self.pid = pid
        self.rssBytes = rssBytes
        self.cpuPercent = cpuPercent
        self.childCount = childCount
        self.pinned = pinned
        self.demoted = demoted
        self.focused = focused
        self.lastActivityMs = lastActivityMs
        self.hibernatedAtMs = hibernatedAtMs
        self.ownedByApp = ownedByApp
    }

    /// Project grouping key: the session's working directory.
    public var projectPath: String { cwd }
    public var projectName: String { (cwd as NSString).lastPathComponent }
}

public struct Totals: Codable, Sendable, Equatable {
    public var rssBytes: UInt64
    public var cpuPercent: Double
    public var count: Int
    public init(rssBytes: UInt64, cpuPercent: Double, count: Int) {
        self.rssBytes = rssBytes
        self.cpuPercent = cpuPercent
        self.count = count
    }
}
