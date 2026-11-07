import CCProtocol
import Foundation
import Testing
@testable import ClaudeTerm

struct DaemonSourceTests {
    let id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

    func session(_ name: String) -> SessionInfo {
        SessionInfo(sessionId: id, cwd: "/w/\(name)", name: name, kind: .interactive, state: .idle)
    }

    @Test func sessionsEventLineYieldsSessionsAndResponsesDoNot() throws {
        let event = try WireLine.encode(Event(event: .sessions, sessions: [session("x")])).dropLast()
        #expect(DaemonLine.sessions(from: event)?.map(\.name) == ["x"])
        let response = try WireLine.encode(Response(id: "app-subscribe", ok: true)).dropLast()
        #expect(DaemonLine.sessions(from: response) == nil)
        let other = try WireLine.encode(Event(event: .hibernated, sessionId: id)).dropLast()
        #expect(DaemonLine.sessions(from: other) == nil)
    }

    @Test func fallsBackToPollingWhenNoDaemon() async {
        let polled = session("polled")
        let modes = Locked<[PreferDaemonSource.Mode]>([])
        let source = PreferDaemonSource(daemon: { nil }, poll: { [polled] }, pollInterval: .milliseconds(1),
                                        onMode: { m in modes.withLock { $0.append(m) } })
        var it = source.updates().makeAsyncIterator()
        #expect(await it.next()?.first?.name == "polled")
        #expect(modes.withLock { $0.first } == .polling)
    }

    @Test func prefersDaemonAndDoesNotPollWhileItIsUp() async {
        let fromDaemon = session("daemon")
        let polls = Locked(0)
        let source = PreferDaemonSource(
            daemon: { AsyncStream { c in c.yield([fromDaemon]) } }, // stays open: daemon still up
            poll: { polls.withLock { $0 += 1 }; return [] },
            pollInterval: .milliseconds(1)
        )
        var it = source.updates().makeAsyncIterator()
        #expect(await it.next()?.first?.name == "daemon")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(polls.withLock { $0 } == 0)
    }
}

@MainActor
struct DaemonNotifyTests {
    let a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    @Test func focusMovesWithSelectionAndPanesAreAttached() throws {
        var sent: [String] = []
        let m = WorkspaceModel(store: nil, claudePath: { "/usr/bin/claude-fake" },
                               notify: { cmd, id in sent.append("\(cmd.rawValue):\(id.prefix(1))") })
        let dir = FileManager.default.temporaryDirectory.path
        m.open(SessionInfo(sessionId: a, cwd: dir, kind: .hibernated, state: .hibernated))
        m.open(SessionInfo(sessionId: b, cwd: dir, kind: .hibernated, state: .hibernated))
        #expect(sent == ["attach:a", "focus:a", "attach:b", "unfocus:a", "focus:b"])
        sent.removeAll()
        m.close(b)
        #expect(sent.prefix(2) == ["detach:b", "unfocus:b"])
        #expect(sent.contains("focus:a"))
    }
}

/// macOS 14 target: Synchronization.Mutex needs 15, so a small NSLock box.
final class Locked<T>: @unchecked Sendable {
    // @unchecked: every access to `value` goes through `lock`.
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
