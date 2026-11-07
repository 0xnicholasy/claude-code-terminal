import CCProtocol
import Darwin
import Foundation

/// Blocking newline-delimited JSON connection to the ccgovd unix socket. Used only off the main thread.
final class DaemonConnection: @unchecked Sendable {
    // @unchecked: the fd and buffer are only touched by the single thread that owns this connection.
    private let fd: Int32
    private var buffer = Data()

    private init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    /// Connects to `path`; nil when no daemon is listening or the socket is not ours.
    static func connect(path: String = SocketPath.resolve()) -> DaemonConnection? {
        guard path.utf8.count <= SocketPath.maxPathBytes else { return nil }
        var st = stat()
        // Refuse a socket owned by another user: its session list would be untrusted input.
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            close(fd)
            return nil
        }
        return DaemonConnection(fd: fd)
    }

    /// Bounded blocking for one-shot requests; a busy or wedged daemon cannot stall the caller forever.
    func setTimeouts(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Unblocks a reader thread parked in read(); the fd itself is closed in deinit.
    func shutdownBoth() { Darwin.shutdown(fd, SHUT_RDWR) }

    func send(_ request: Request) -> Bool {
        guard let data = try? WireLine.encode(request) else { return false }
        return data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off) // baseAddress: non-empty encoded line
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    /// Next line without the newline; nil on EOF, error, or a line longer than the protocol allows.
    func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            // Events carry the full session list, so allow more than one request line.
            if buffer.count > 16 * WireLine.maxBytes { return nil }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(chunk, count: n)
        }
    }
}

enum DaemonLine {
    /// Session list carried by a `sessions` event line; nil for responses and other events.
    static func sessions(from line: Data) -> [SessionInfo]? {
        guard let event = try? WireLine.decode(Event.self, from: line), event.event == .sessions else { return nil }
        return event.sessions
    }
}

/// Subscribes to ccgovd; the stream ends when the daemon goes away.
struct DaemonSocketSource: SessionSource {
    var path: String = SocketPath.resolve()

    /// nil when no daemon is reachable right now.
    func connectStream() -> AsyncStream<[SessionInfo]>? {
        guard let conn = DaemonConnection.connect(path: path),
              conn.send(Request(id: "app-subscribe", cmd: .subscribe)) else { return nil }
        return AsyncStream { continuation in
            let thread = Thread {
                while let line = conn.readLine() {
                    if let list = DaemonLine.sessions(from: line) { continuation.yield(list) }
                }
                continuation.finish()
            }
            // Consumer gone: shut the socket so the reader thread returns and the fd is released.
            continuation.onTermination = { _ in conn.shutdownBoth() }
            thread.start()
        }
    }

    func updates() -> AsyncStream<[SessionInfo]> {
        connectStream() ?? AsyncStream { $0.finish() }
    }
}

/// Uses the daemon when it is up; otherwise polls `claude agents --json` and re-tries the socket.
struct PreferDaemonSource: SessionSource {
    var daemon: @Sendable () -> AsyncStream<[SessionInfo]>?
    var poll: @Sendable () async -> [SessionInfo]?
    var pollInterval: Duration = .seconds(5)
    var retryEvery: Int = 2 // poll cycles between socket attempts (10 s at the default interval)
    var onMode: @Sendable (Mode) -> Void = { _ in }

    enum Mode: Equatable, Sendable { case daemon, polling }

    func updates() -> AsyncStream<[SessionInfo]> {
        let me = self
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    if let stream = me.daemon() {
                        me.onMode(.daemon)
                        for await list in stream { continuation.yield(list) }
                    }
                    me.onMode(.polling)
                    for _ in 0..<max(1, me.retryEvery) where !Task.isCancelled {
                        if let list = await me.poll() { continuation.yield(list) }
                        try? await Task.sleep(for: me.pollInterval)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func live(claude: ClaudeBinary, onMode: @escaping @Sendable (Mode) -> Void) -> PreferDaemonSource {
        let socket = DaemonSocketSource()
        return PreferDaemonSource(
            daemon: { socket.connectStream() },
            poll: { await AgentsPollingSource.snapshot(claude: claude) },
            onMode: onMode
        )
    }
}

/// Fire-and-forget notifications to ccgovd (focus, attach). Silently does nothing without a daemon.
enum DaemonNotifier {
    private static let queue = DispatchQueue(label: "ccterm.daemon-notify")

    static func send(_ cmd: Command, sessionId: String) {
        guard SessionID.isValid(sessionId) else { return }
        queue.async {
            guard let conn = DaemonConnection.connect() else { return }
            conn.setTimeouts(seconds: 2)
            _ = conn.send(Request(id: "app-\(cmd.rawValue)", cmd: cmd, sessionId: sessionId))
            _ = conn.readLine()
        }
    }
}

enum DaemonClient {
    /// One request on a fresh connection; nil when the daemon is down or does not answer within 5 s.
    static func request(_ cmd: Command, sessionId: String) async -> Response? {
        guard SessionID.isValid(sessionId) else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let conn = DaemonConnection.connect() else { return cont.resume(returning: nil) }
                conn.setTimeouts(seconds: 5)
                guard conn.send(Request(id: "app-\(cmd.rawValue)", cmd: cmd, sessionId: sessionId)),
                      let line = conn.readLine() else { return cont.resume(returning: nil) }
                cont.resume(returning: try? WireLine.decode(Response.self, from: line))
            }
        }
    }
}
