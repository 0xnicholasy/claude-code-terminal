import Foundation
import CCProtocol

public struct GovernPolicy: Equatable {
    public var demoteAfterMs: Int64 = 60_000
    public var hibernateAfterMs: Int64 = 30 * 60_000
    public init(demoteAfterMs: Int64 = 60_000, hibernateAfterMs: Int64 = 30 * 60_000) {
        self.demoteAfterMs = demoteAfterMs
        self.hibernateAfterMs = hibernateAfterMs
    }
}

public struct GovernView: Equatable {
    public var sessionId: String
    public var kind: SessionKind
    public var state: SessionState
    public var hasPid: Bool
    public var pinned: Bool
    public var demoted: Bool
    public var focused: Bool
    public var lastActivityMs: Int64?
    public var hasShellDescendant: Bool

    public init(sessionId: String, kind: SessionKind = .interactive, state: SessionState = .idle, hasPid: Bool = true,
                pinned: Bool = false, demoted: Bool = false, focused: Bool = false,
                lastActivityMs: Int64? = nil, hasShellDescendant: Bool = false) {
        self.sessionId = sessionId
        self.kind = kind
        self.state = state
        self.hasPid = hasPid
        self.pinned = pinned
        self.demoted = demoted
        self.focused = focused
        self.lastActivityMs = lastActivityMs
        self.hasShellDescendant = hasShellDescendant
    }
}

public enum GovernAction: Equatable {
    case demote(String)
    case restore(String)
    case hibernate(String)
}

/// Pure policy. Only interactive sessions with a live pid are ever considered; background sessions are read only.
public enum Governor {
    public static func decide(views: [GovernView], nowMs: Int64, policy: GovernPolicy) -> [GovernAction] {
        var actions: [GovernAction] = []
        for v in views where v.kind == .interactive && v.hasPid {
            let quiet = v.state == .idle || v.state == .blocked
            if v.demoted && (v.focused || v.state == .running) {
                actions.append(.restore(v.sessionId))
                continue
            }
            guard quiet, !v.focused, let last = v.lastActivityMs else { continue }
            let idleMs = nowMs - last
            if idleMs >= policy.hibernateAfterMs && !v.pinned && !v.hasShellDescendant {
                actions.append(.hibernate(v.sessionId))
            } else if idleMs >= policy.demoteAfterMs && !v.demoted {
                actions.append(.demote(v.sessionId))
            }
        }
        return actions
    }
}
