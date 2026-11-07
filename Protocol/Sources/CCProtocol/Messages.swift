import Foundation

public enum Command: String, Codable, Sendable {
    case list, status, focus, unfocus, demote, restore, hibernate, pin, unpin, resume, attach, detach, subscribe, hook
}

/// Payload forwarded by `ccgovd hook` from a Claude Code hook (stdin JSON).
public struct HookEvent: Codable, Sendable, Equatable {
    public var hookEventName: String
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
    }

    public init(hookEventName: String, sessionId: String, cwd: String? = nil, transcriptPath: String? = nil) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
    }
}

public struct Request: Codable, Sendable, Equatable {
    public var id: String
    public var cmd: Command
    public var sessionId: String?
    public var hook: HookEvent?

    public init(id: String, cmd: Command, sessionId: String? = nil, hook: HookEvent? = nil) {
        self.id = id
        self.cmd = cmd
        self.sessionId = sessionId
        self.hook = hook
    }
}

public struct Response: Codable, Sendable, Equatable {
    public var id: String
    public var ok: Bool
    public var error: String?
    public var sessions: [SessionInfo]?
    public var totals: Totals?
    public var command: ResumeCommand?

    public init(id: String, ok: Bool, error: String? = nil, sessions: [SessionInfo]? = nil,
                totals: Totals? = nil, command: ResumeCommand? = nil) {
        self.id = id
        self.ok = ok
        self.error = error
        self.sessions = sessions
        self.totals = totals
        self.command = command
    }
}

public enum EventKind: String, Codable, Sendable {
    case sessions, hibernated, resumed, demoted, restored
}

public struct Event: Codable, Sendable, Equatable {
    public var event: EventKind
    public var sessionId: String?
    public var sessions: [SessionInfo]?

    public init(event: EventKind, sessionId: String? = nil, sessions: [SessionInfo]? = nil) {
        self.event = event
        self.sessionId = sessionId
        self.sessions = sessions
    }
}

/// One JSON line on the wire. Lines from the daemon are either a Response (has "id") or an Event (has "event").
public enum WireLine {
    public static let maxBytes = 64 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

public enum SocketPath {
    /// `~/Library/Application Support/ccgovd/ccgovd.sock`, or `$CCGOVD_SOCKET`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = environment["CCGOVD_SOCKET"], !p.isEmpty { return p }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return home + "/Library/Application Support/ccgovd/ccgovd.sock"
    }

    /// sockaddr_un.sun_path is 104 bytes on Darwin including the NUL.
    public static let maxPathBytes = 103
}
