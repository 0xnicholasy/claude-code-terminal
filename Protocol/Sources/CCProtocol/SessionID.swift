import Foundation

/// Validated Claude session id (a UUID). Every id that reaches an argv or a path goes through this.
public enum SessionID {
    public static func isValid(_ s: String) -> Bool {
        guard s.count == 36, let uuid = UUID(uuidString: s) else { return false }
        return uuid.uuidString.lowercased() == s.lowercased()
    }
}

/// Command that resumes a session: argv for direct exec, shellLine for pasting into a terminal.
public struct ResumeCommand: Codable, Sendable, Equatable {
    public var cwd: String
    public var argv: [String]
    public var shellLine: String

    /// Returns nil when `sessionId` is not a UUID.
    public static func make(sessionId: String, cwd: String, claude: String = "claude") -> ResumeCommand? {
        guard SessionID.isValid(sessionId) else { return nil }
        let argv = [claude, "--resume", sessionId]
        let line = "cd \(shellQuote(cwd)) && \(shellQuote(claude)) --resume \(sessionId)"
        return ResumeCommand(cwd: cwd, argv: argv, shellLine: line)
    }

    public init(cwd: String, argv: [String], shellLine: String) {
        self.cwd = cwd
        self.argv = argv
        self.shellLine = shellLine
    }
}

/// POSIX single-quote escaping: 'it'\''s'.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
