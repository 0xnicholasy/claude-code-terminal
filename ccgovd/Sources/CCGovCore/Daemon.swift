import Foundation
import CCProtocol

public struct DaemonConfig {
    public var govern = false
    public var intervalSec: Double = 5
    public var idleMs: Int64 = 30 * 60_000
    public var socketPath: String = SocketPath.resolve()
    public var dbPath: String = DaemonConfig.defaultDBPath()
    public var allowPids: Set<Int32>?
    public var scopeCwdPrefix: String?
    public var once = false
    public var claudePath: String = "claude"

    public init() {}

    public static func defaultDBPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = environment["CCGOVD_DB"], !p.isEmpty { return p }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return home + "/Library/Application Support/ccgovd/ccgovd.db"
    }
}

public func logLine(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(ts) ccgovd: \(s)\n".utf8))
}

/// Owns the store, the index cycle, the governor, and request handling. All state lives on one serial queue.
public final class Daemon {
    public let config: DaemonConfig
    let store: SessionStore
    let index: SessionIndex
    let gate: SignalGate
    let governor: ProcessGovernor
    let time: TimeSource
    private let q = DispatchQueue(label: "ccgovd.state")
    private var snapshot = IndexSnapshot()
    private var focused: Set<String> = []
    private var owned: Set<String> = []
    private var subscribers: [ObjectIdentifier: ClientHandle] = [:]
    private var server: SocketServer?
    private var timer: DispatchSourceTimer?
    public var log: (String) -> Void

    public init(config: DaemonConfig, store: SessionStore, runner: AgentsRunner, table: ProcessTable,
                sender: SignalSender, time: TimeSource, transcripts: TranscriptProbe,
                log: @escaping (String) -> Void = logLine) {
        self.config = config
        self.store = store
        self.time = time
        self.log = log
        self.index = SessionIndex(store: store, runner: runner, table: table, time: time, transcripts: transcripts)
        self.index.log = log
        self.gate = SignalGate(sender: sender, table: table, allowPids: config.allowPids,
                               scopeCwdPrefix: config.scopeCwdPrefix, log: log)
        self.governor = ProcessGovernor(gate: gate, table: table, time: time)
    }

    private var policy: GovernPolicy { GovernPolicy(demoteAfterMs: 60_000, hibernateAfterMs: config.idleMs) }

    // MARK: lifecycle

    public func start() throws {
        let srv = SocketServer(path: config.socketPath,
                               handler: { [weak self] req, client in
                                   self?.handle(req, client: client) ?? Response(id: req.id, ok: false, error: "shutting down")
                               },
                               onClose: { [weak self] client in
                                   self?.q.async { self?.subscribers[ObjectIdentifier(client)] = nil }
                               },
                               onSubscribed: { [weak self] client in
                                   self?.q.async { self?.addSubscriber(client) }
                               })
        try srv.start()
        server = srv
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: config.intervalSec)
        t.setEventHandler { [weak self] in self?.cycle() }
        t.resume()
        timer = t
        log("listening on \(config.socketPath) govern=\(config.govern) interval=\(config.intervalSec)s idleMs=\(config.idleMs)")
    }

    public func stop() {
        timer?.cancel()
        server?.stop()
    }

    /// One index + govern cycle, synchronously. Used by `run --once` and by tests.
    public func runCycle() -> IndexSnapshot {
        q.sync { cycle(); return snapshot }
    }

    /// Index only, no policy: the in-process fallback for a single CLI action must touch only that session.
    public func indexOnce() {
        q.sync { snapshot = index.poll(focused: focused, owned: owned) }
    }

    /// Index + metrics only (no governing, no socket): the in-process `ccgovd status`.
    public func statusOnce() -> IndexSnapshot {
        q.sync {
            index.primeCPU()
            time.sleep(ms: 400)
            snapshot = index.poll(focused: focused, owned: owned)
            return snapshot
        }
    }

    private func cycle() {
        snapshot = index.poll(focused: focused, owned: owned)
        for id in snapshot.resumed { broadcast(Event(event: .resumed, sessionId: id)) }
        if config.govern { applyPolicy() }
        broadcast(Event(event: .sessions, sessions: snapshot.sessions))
    }

    private func applyPolicy() {
        let scoped = snapshot.views.filter { v in snapshot.targets[v.sessionId].map(gate.inScope) ?? false }
        let actions = Governor.decide(views: scoped, nowMs: time.nowMs(), policy: policy)
        var acted = false
        for a in actions {
            switch a {
            case .demote(let id): acted = demote(id, background: true).ok || acted
            case .restore(let id): acted = demote(id, background: false).ok || acted
            case .hibernate(let id): acted = hibernate(id).ok || acted
            }
        }
        if acted { snapshot = index.repoll(focused: focused, owned: owned) }
    }

    // MARK: actions (queue-confined)

    private func demote(_ id: String, background: Bool) -> (ok: Bool, msg: String) {
        guard config.govern else { return (false, "read-only: start the daemon with --govern") }
        guard let target = snapshot.targets[id] else { return (false, "session is not a live interactive session") }
        let out = governor.setBackground(background, target: target)
        let detail = out.results.map { "\($0.pid):\($0.applied ? ($0.verified ? "ok" : "unverified") : "refused")" }.joined(separator: " ")
        let rootOK = out.results.first(where: { $0.pid == target.rootPid })?.verified ?? false
        // Every tracked process still alive must carry the new priority; one that exited meanwhile is fine.
        let treeOK = out.results.allSatisfy { $0.verified || !governor.stillAlive($0.pid, target: target) }
        if rootOK && treeOK {
            try? store.setDemoted(id, background)
            log("\(background ? "demoted" : "restored") \(id.prefix(8)) [\(detail)]")
            broadcast(Event(event: background ? .demoted : .restored, sessionId: id))
            return (true, detail)
        }
        log("\(background ? "demote" : "restore") \(id.prefix(8)) failed [\(detail)]")
        return (false, "not applied: \(detail)")
    }

    private func hibernate(_ id: String) -> (ok: Bool, msg: String) {
        guard config.govern else { return (false, "read-only: start the daemon with --govern") }
        guard let target = snapshot.targets[id] else { return (false, "session is not a live interactive session") }
        let out = governor.hibernate(target: target)
        guard out.complete else {
            let why = out.refused ?? "root gone: \(out.rootGone), survivors \(out.survivors)"
            log("hibernate \(id.prefix(8)) failed: \(why)")
            return (false, "not hibernated: \(why)")
        }
        try? store.markHibernated(id, atMs: time.nowMs())
        let mb = Double(out.rssFreedBytes) / 1_048_576
        log(String(format: "hibernated %@ freed %.1f MB rss across %d processes (killed %d)",
                   String(id.prefix(8)), mb, out.terminated.count, out.killed.count))
        broadcast(Event(event: .hibernated, sessionId: id))
        return (true, "")
    }

    private func addSubscriber(_ client: ClientHandle) {
        subscribers[ObjectIdentifier(client)] = client
        _ = client.send(Event(event: .sessions, sessions: snapshot.sessions))
    }

    private func broadcast<T: Encodable>(_ event: T) {
        for (key, c) in subscribers where !c.send(event) { subscribers[key] = nil }
    }

    // MARK: requests

    public func handle(_ req: Request, client: ClientHandle?) -> Response {
        q.sync { handleLocked(req, client: client) }
    }

    private func handleLocked(_ req: Request, client: ClientHandle?) -> Response {
        func fail(_ m: String) -> Response { Response(id: req.id, ok: false, error: m) }
        func ok() -> Response { Response(id: req.id, ok: true) }

        switch req.cmd {
        case .list:
            return Response(id: req.id, ok: true, sessions: snapshot.sessions)
        case .status:
            snapshot = index.repoll(focused: focused, owned: owned)
            return Response(id: req.id, ok: true, sessions: snapshot.sessions, totals: snapshot.totals)
        case .subscribe:
            // Registration happens in addSubscriber, after the server has written this response.
            guard client != nil else { return fail("subscribe needs a connection") }
            return ok()
        case .hook:
            guard let h = req.hook, SessionID.isValid(h.sessionId) else { return fail("hook needs a valid session_id") }
            index.noteActivity(sessionId: h.sessionId, atMs: time.nowMs())
            return ok()
        default:
            break
        }

        guard let id = req.sessionId, SessionID.isValid(id) else { return fail("sessionId must be a UUID") }
        switch req.cmd {
        case .focus:
            focused.insert(id)
            if let row = try? store.row(id), row.demoted, config.govern {
                snapshot = index.repoll(focused: focused, owned: owned)
                _ = demote(id, background: false)
            }
            snapshot = index.repoll(focused: focused, owned: owned)
            return ok()
        case .unfocus:
            focused.remove(id)
        case .attach:
            owned.insert(id)
        case .detach:
            owned.remove(id)
        case .pin, .unpin:
            guard (try? store.row(id)) != nil else { return fail("unknown session") }
            try? store.setPinned(id, req.cmd == .pin)
        case .resume:
            guard let row = try? store.row(id) else { return fail("unknown session") }
            guard let cmd = ResumeCommand.make(sessionId: id, cwd: row.cwd) else { return fail("invalid session id") }
            return Response(id: req.id, ok: true, command: cmd)
        case .demote, .restore, .hibernate:
            snapshot = index.repoll(focused: focused, owned: owned)
            let r: (ok: Bool, msg: String)
            switch req.cmd {
            case .demote: r = demote(id, background: true)
            case .restore: r = demote(id, background: false)
            default: r = hibernate(id)
            }
            snapshot = index.repoll(focused: focused, owned: owned)
            return r.ok ? ok() : fail(r.msg)
        default:
            return fail("unsupported command")
        }
        snapshot = index.repoll(focused: focused, owned: owned)
        return ok()
    }
}
