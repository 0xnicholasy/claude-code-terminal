import Foundation
import CCProtocol

public enum AgentKind: String {
    case interactive
    case background
}

/// One entry of `claude agents --json`. Interactive entries carry `pid` + `status`;
/// background entries carry `id` + `state` and no pid. Unknown fields are ignored, missing ones tolerated.
public struct AgentEntry: Decodable, Equatable {
    public var pid: Int32?
    public var cwd: String
    public var kind: AgentKind
    public var startedAt: Int64?
    public var sessionId: String
    public var name: String?
    public var rawState: String?

    enum CodingKeys: String, CodingKey { case pid, cwd, kind, startedAt, sessionId, name, status, state }

    public init(pid: Int32? = nil, cwd: String, kind: AgentKind, startedAt: Int64? = nil,
                sessionId: String, name: String? = nil, rawState: String? = nil) {
        self.pid = pid
        self.cwd = cwd
        self.kind = kind
        self.startedAt = startedAt
        self.sessionId = sessionId
        self.name = name
        self.rawState = rawState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pid = try? c.decodeIfPresent(Int32.self, forKey: .pid)
        self.pid = pid
        self.cwd = (try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        let rawKind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        switch rawKind {
        case "interactive": self.kind = .interactive
        case "background": self.kind = .background
        default: self.kind = pid != nil ? .interactive : .background
        }
        if let i = try? c.decodeIfPresent(Int64.self, forKey: .startedAt) {
            self.startedAt = i
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .startedAt) {
            self.startedAt = Int64(d)
        } else {
            self.startedAt = nil
        }
        self.sessionId = (try? c.decodeIfPresent(String.self, forKey: .sessionId)) ?? ""
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        let status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
        let state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil
        self.rawState = status ?? state
    }

    public var state: SessionState { SessionState(agentsRaw: rawState) }

    /// Decode the array printed by `claude agents --json`; entries without a valid session id are dropped.
    public static func decodeList(_ data: Data) throws -> [AgentEntry] {
        try JSONDecoder().decode([AgentEntry].self, from: data).filter { SessionID.isValid($0.sessionId) }
    }
}

public protocol AgentsRunner {
    func run() throws -> [AgentEntry]
}

public enum ClaudeLocator {
    /// `CCTERM_CLAUDE_PATH`, else `/bin/zsh -lc 'command -v claude'`, else `~/.local/bin/claude`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = environment["CCTERM_CLAUDE_PATH"], !p.isEmpty { return p }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        if (try? proc.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if proc.terminationStatus == 0, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return (environment["HOME"] ?? NSHomeDirectory()) + "/.local/bin/claude"
    }
}

public struct AgentsRunError: Error, CustomStringConvertible {
    public var description: String
}

/// Runs the real `claude agents --json` with a timeout.
public struct ClaudeAgentsRunner: AgentsRunner {
    public var claudePath: String
    public var timeoutSeconds: Double = 20
    public init(claudePath: String, timeoutSeconds: Double = 20) {
        self.claudePath = claudePath
        self.timeoutSeconds = timeoutSeconds
    }

    public func run() throws -> [AgentEntry] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = ["agents", "--json"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        try proc.run()
        let timer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        timer.cancel()
        guard proc.terminationStatus == 0 else {
            throw AgentsRunError(description: "claude agents --json exited \(proc.terminationStatus)")
        }
        return try AgentEntry.decodeList(data)
    }
}

/// Transcript presence and mtime only. The JSONL body is never opened.
public protocol TranscriptProbe {
    func mtimeMs(sessionId: String) -> Int64?
}

public struct FileTranscriptProbe: TranscriptProbe {
    public var projectsDir: String
    public init(projectsDir: String = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.claude/projects") {
        self.projectsDir = projectsDir
    }

    public func mtimeMs(sessionId: String) -> Int64? {
        guard SessionID.isValid(sessionId) else { return nil }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
        var best: Int64?
        for d in dirs {
            let path = projectsDir + "/" + d + "/" + sessionId + ".jsonl"
            var st = stat()
            if stat(path, &st) == 0 {
                let ms = Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
                best = max(best ?? 0, ms)
            }
        }
        return best
    }
}
