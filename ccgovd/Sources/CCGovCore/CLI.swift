import Foundation
import Darwin
import CCProtocol

public struct ParsedArgs {
    public var command: String?
    public var positional: [String] = []
    public var values: [String: String] = [:]
    public var flags: Set<String> = []
}

public enum CLI {
    static let valueOptions: Set<String> = ["interval", "idle-minutes", "idle-seconds", "socket", "db", "allow-pids", "scope-cwd-prefix"]
    static let boolOptions: Set<String> = ["govern", "once", "json"]

    public static func parse(_ args: [String]) throws -> ParsedArgs {
        var p = ParsedArgs()
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    let k = String(body[..<eq])
                    guard valueOptions.contains(k) else { throw CLIError("unknown option --\(k)") }
                    p.values[k] = String(body[body.index(after: eq)...])
                } else if valueOptions.contains(body) {
                    i += 1
                    guard i < args.count else { throw CLIError("--\(body) needs a value") }
                    p.values[body] = args[i]
                } else if boolOptions.contains(body) {
                    p.flags.insert(body)
                } else {
                    throw CLIError("unknown option --\(body)")
                }
            } else if p.command == nil {
                p.command = a
            } else {
                p.positional.append(a)
            }
            i += 1
        }
        return p
    }

    public static func parsePids(_ s: String) throws -> Set<Int32> {
        var out: Set<Int32> = []
        for part in s.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            guard let n = Int32(part), n > 1 else { throw CLIError("bad pid '\(part)'") }
            out.insert(n)
        }
        return out
    }

    public static func config(from p: ParsedArgs, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> DaemonConfig {
        var c = DaemonConfig()
        c.govern = p.flags.contains("govern")
        c.once = p.flags.contains("once")
        if let s = p.values["interval"] {
            guard let d = Double(s), d > 0 else { throw CLIError("bad --interval") }
            c.intervalSec = d
        }
        if let s = p.values["idle-seconds"] {
            guard let n = Double(s), n >= 0 else { throw CLIError("bad --idle-seconds") }
            c.idleMs = Int64(n * 1000)
        } else if let s = p.values["idle-minutes"] {
            guard let n = Double(s), n >= 0 else { throw CLIError("bad --idle-minutes") }
            c.idleMs = Int64(n * 60_000)
        }
        if let s = p.values["socket"] { c.socketPath = s } else { c.socketPath = SocketPath.resolve(environment: environment) }
        if let s = p.values["db"] { c.dbPath = s } else { c.dbPath = DaemonConfig.defaultDBPath(environment: environment) }
        if let s = p.values["allow-pids"] ?? environment["CCGOVD_ALLOW_PIDS"], p.values["allow-pids"] != nil || !s.isEmpty {
            c.allowPids = try parsePids(s)
        }
        c.scopeCwdPrefix = p.values["scope-cwd-prefix"]
        return c
    }

    static let usage = """
    usage: ccgovd run [--govern] [--interval s] [--idle-minutes n|--idle-seconds n] [--socket p] [--db p]
                      [--allow-pids a,b] [--scope-cwd-prefix p] [--once]
           ccgovd status [--json] [--socket p]
           ccgovd demote|restore|hibernate|pin|unpin|resume <sessionId> [--socket p]
           ccgovd hook          (Claude Code hook JSON on stdin)
    """

    public static func main(_ args: [String]) -> Int32 {
        do {
            let p = try parse(args)
            switch p.command {
            case "run": return try run(p)
            case "status": return try status(p)
            case "demote", "restore", "hibernate", "pin", "unpin", "resume": return try act(p)
            case "hook": return hook(p)
            default:
                FileHandle.standardError.write(Data((usage + "\n").utf8))
                return p.command == nil ? 0 : 2
            }
        } catch {
            FileHandle.standardError.write(Data("ccgovd: \(error)\n".utf8))
            return 1
        }
    }

    static func makeDaemon(_ cfg: DaemonConfig, store: SessionStore) -> Daemon {
        var cfg = cfg
        if cfg.claudePath == "claude" { cfg.claudePath = ClaudeLocator.resolve() }
        return Daemon(config: cfg, store: store, runner: ClaudeAgentsRunner(claudePath: cfg.claudePath),
                      table: DarwinProcessTable(), sender: SystemSignalSender(), time: SystemTime(),
                      transcripts: FileTranscriptProbe())
    }

    // MARK: run

    static func run(_ p: ParsedArgs) throws -> Int32 {
        let cfg = try config(from: p)
        if cfg.govern && cfg.allowPids == nil {
            logLine("governing WITHOUT a test allowlist: every interactive session on this machine is in scope")
        }
        let store = try SessionStore(path: cfg.dbPath)
        let daemon = makeDaemon(cfg, store: store)
        if cfg.once {
            let snap = daemon.runCycle()
            logLine("once: \(snap.sessions.count) sessions")
            return 0
        }
        try daemon.start()
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { daemon.stop(); exit(0) }
            src.resume()
            signalSources.append(src)
        }
        dispatchMain()
    }

    nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    // MARK: status

    static func status(_ p: ParsedArgs) throws -> Int32 {
        let cfg = try config(from: p)
        let sessions: [SessionInfo]
        let totals: Totals
        if let r = SocketClient.request(path: cfg.socketPath, Request(id: "cli", cmd: .status)), r.ok, let s = r.sessions {
            sessions = s
            totals = r.totals ?? Totals(rssBytes: s.reduce(0) { $0 + $1.rssBytes }, cpuPercent: s.reduce(0) { $0 + $1.cpuPercent }, count: s.count)
        } else {
            // No daemon: one-shot index + metrics in memory. Read only; nothing is signalled or persisted.
            var c = cfg
            c.dbPath = p.values["db"] ?? ":memory:"
            c.govern = false
            let daemon = makeDaemon(c, store: try SessionStore(path: c.dbPath))
            let snap = daemon.statusOnce()
            sessions = snap.sessions
            totals = snap.totals
        }
        if p.flags.contains("json") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            struct Out: Encodable { var sessions: [SessionInfo]; var totals: Totals }
            print(String(decoding: try enc.encode(Out(sessions: sessions, totals: totals)), as: UTF8.self))
        } else {
            print(renderTable(sessions, totals: totals))
        }
        return 0
    }

    public static func renderTable(_ sessions: [SessionInfo], totals: Totals) -> String {
        func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
            let t = s.count > w ? String(s.prefix(w)) : s
            let fill = String(repeating: " ", count: w - t.count)
            return right ? fill + t : t + fill
        }
        var lines = [pad("SESSION", 8) + "  " + pad("PROJECT", 24) + "  " + pad("STATE", 10) + "  " + pad("PID", 7, right: true)
                     + "  " + pad("RSS MB", 8, right: true) + "  " + pad("CPU%", 6, right: true) + "  " + pad("CHILDREN", 8, right: true) + "  FLAGS"]
        for s in sessions {
            var flags = ""
            if s.pinned { flags += "P" }
            if s.demoted { flags += "D" }
            if s.focused { flags += "F" }
            lines.append(pad(String(s.sessionId.prefix(8)), 8) + "  " + pad(s.projectName, 24) + "  " + pad(s.state.rawValue, 10)
                         + "  " + pad(s.pid.map(String.init) ?? "-", 7, right: true)
                         + "  " + pad(String(format: "%.1f", Double(s.rssBytes) / 1_048_576), 8, right: true)
                         + "  " + pad(String(format: "%.1f", s.cpuPercent), 6, right: true)
                         + "  " + pad(String(s.childCount), 8, right: true) + "  " + flags)
        }
        lines.append(String(format: "TOTAL %d sessions, %.1f MB rss, %.1f%% cpu", totals.count,
                            Double(totals.rssBytes) / 1_048_576, totals.cpuPercent))
        return lines.joined(separator: "\n")
    }

    // MARK: demote | restore | hibernate | pin | unpin | resume

    static func act(_ p: ParsedArgs) throws -> Int32 {
        guard let cmdName = p.command, let cmd = Command(rawValue: cmdName) else { throw CLIError("bad command") }
        guard let id = p.positional.first, SessionID.isValid(id) else { throw CLIError("\(cmdName) needs a session UUID") }
        let cfg = try config(from: p)
        let req = Request(id: "cli", cmd: cmd, sessionId: id)
        let resp: Response
        if let r = SocketClient.request(path: cfg.socketPath, req) {
            resp = r
        } else if cmd == .resume || cmd == .pin || cmd == .unpin {
            let store = try SessionStore(path: cfg.dbPath)
            resp = makeDaemon(cfg, store: store).handle(req, client: nil)
        } else {
            // Daemon down: run the action in-process through the same SignalGate. Needs --govern.
            guard cfg.govern else {
                throw CLIError("daemon not reachable at \(cfg.socketPath); pass --govern (plus --allow-pids/--scope-cwd-prefix in test mode) to act in-process")
            }
            let store = try SessionStore(path: cfg.dbPath)
            let daemon = makeDaemon(cfg, store: store)
            daemon.indexOnce() // not runCycle(): the policy would act on every other in-scope session too
            resp = daemon.handle(req, client: nil)
        }
        if !resp.ok {
            FileHandle.standardError.write(Data("ccgovd: \(resp.error ?? "failed")\n".utf8))
            return 1
        }
        if cmd == .resume, let c = resp.command { print(c.shellLine) } else { print("ok") }
        return 0
    }

    // MARK: hook

    /// Always exits 0, within about one second, whatever happens.
    static func hook(_ p: ParsedArgs) -> Int32 {
        signal(SIGALRM) { _ in _exit(0) }
        alarm(1)
        let input = FileHandle.standardInput.readData(ofLength: WireLine.maxBytes)
        guard let ev = try? JSONDecoder().decode(HookEvent.self, from: input), SessionID.isValid(ev.sessionId) else { return 0 }
        let path = SocketPath.resolve()
        _ = SocketClient.request(path: path, Request(id: "hook", cmd: .hook, hook: ev), timeoutSec: 1)
        return 0
    }
}

public struct CLIError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}
