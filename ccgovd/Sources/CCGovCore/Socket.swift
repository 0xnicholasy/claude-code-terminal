import Foundation
import Darwin
import CCProtocol

public struct SocketError: Error, CustomStringConvertible {
    public var description: String
}

private func makeAddr(_ path: String) throws -> sockaddr_un {
    guard path.utf8.count <= SocketPath.maxPathBytes else {
        throw SocketError(description: "socket path is \(path.utf8.count) bytes, max \(SocketPath.maxPathBytes)")
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            _ = path.withCString { strncpy(dst, $0, 103) }
        }
    }
    return addr
}

private func withSockaddr<R>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var off = 0
    return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
        while off < data.count {
            let n = write(fd, buf.baseAddress! + off, data.count - off)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            off += n
        }
        return true
    }
}

/// A connected client. `send` is safe to call from any thread.
public final class ClientHandle {
    public let fd: Int32
    private let lock = NSLock()
    private(set) var closed = false

    init(fd: Int32) { self.fd = fd }

    @discardableResult
    public func send<T: Encodable>(_ value: T) -> Bool {
        guard let data = try? WireLine.encode(value) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        return writeAll(fd, data)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed { closed = true; Darwin.close(fd) }
    }
}

/// Newline-delimited JSON over a unix stream socket (SPEC section 4).
public final class SocketServer {
    public typealias Handler = (Request, ClientHandle) -> Response
    public let path: String
    private let handler: Handler
    private let onClose: (ClientHandle) -> Void
    private var listenFd: Int32 = -1
    private var stopping = false

    public init(path: String, handler: @escaping Handler, onClose: @escaping (ClientHandle) -> Void = { _ in }) {
        self.path = path
        self.handler = handler
        self.onClose = onClose
    }

    public func start() throws {
        var addr = try makeAddr(path)
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dir, isDirectory: &isDir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else if isDir.boolValue {
            // Tighten only our own dedicated daemon directory, never a shared one like /tmp.
            var st = stat()
            if stat(dir, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 != 0,
               (dir as NSString).lastPathComponent == "ccgovd" {
                chmod(dir, 0o700)
            }
        }
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else {
                throw SocketError(description: "\(path) exists and is not a socket owned by this user; refusing to remove")
            }
            if SocketClient.probe(path: path) {
                throw SocketError(description: "a daemon is already listening on \(path)")
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(description: "socket(): errno \(errno)") }
        let old = umask(0o177)
        let rc = withSockaddr(&addr) { bind(fd, $0, $1) }
        umask(old)
        guard rc == 0 else { close(fd); throw SocketError(description: "bind \(path): errno \(errno)") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw SocketError(description: "listen: errno \(errno)") }
        listenFd = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        stopping = true
        if listenFd >= 0 { close(listenFd); listenFd = -1 }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while !stopping {
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); continue }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let handle = ClientHandle(fd: c)
            Thread.detachNewThread { [weak self] in self?.serve(handle) }
        }
    }

    private func serve(_ client: ClientHandle) {
        defer { onClose(client); client.close() }
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(client.fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            buf.append(chunk, count: n)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                if line.count > WireLine.maxBytes { return oversize(client) }
                if line.isEmpty { continue }
                client.send(respond(to: line, client: client))
            }
            if buf.count > WireLine.maxBytes { return oversize(client) }
        }
    }

    private func oversize(_ client: ClientHandle) {
        client.send(Response(id: "", ok: false, error: "line exceeds \(WireLine.maxBytes) bytes"))
        // Drain what the peer is still sending so close() does not reset the connection before it reads the error.
        shutdown(client.fd, SHUT_WR)
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(client.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var sink = [UInt8](repeating: 0, count: 65536)
        var drained = 0
        while drained < 4 * 1024 * 1024 {
            let n = read(client.fd, &sink, sink.count)
            if n <= 0 { break }
            drained += n
        }
    }

    private func respond(to line: Data, client: ClientHandle) -> Response {
        do {
            let req = try WireLine.decode(Request.self, from: line)
            return handler(req, client)
        } catch {
            var id = ""
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let s = obj["id"] as? String { id = s }
            return Response(id: id, ok: false, error: "malformed or unknown request")
        }
    }
}

public enum SocketClient {
    private static func connectFd(_ path: String, timeoutSec: Int) -> Int32? {
        guard var addr = try? makeAddr(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard withSockaddr(&addr, { connect(fd, $0, $1) }) == 0 else { close(fd); return nil }
        return fd
    }

    /// True when something accepts connections on `path`.
    public static func probe(path: String) -> Bool {
        guard let fd = connectFd(path, timeoutSec: 1) else { return false }
        close(fd)
        return true
    }

    /// Send one request, read one response line. Nil when the daemon is unreachable or the reply is unusable.
    public static func request(path: String, _ req: Request, timeoutSec: Int = 10) -> Response? {
        guard let fd = connectFd(path, timeoutSec: timeoutSec), let data = try? WireLine.encode(req) else { return nil }
        defer { close(fd) }
        guard writeAll(fd, data) else { return nil }
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buf.count <= WireLine.maxBytes * 4 {
            if let nl = buf.firstIndex(of: 0x0A) {
                return try? WireLine.decode(Response.self, from: buf.subdata(in: buf.startIndex..<nl))
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            buf.append(chunk, count: n)
        }
        return nil
    }

    /// Raw bytes in, raw first line out (tests and diagnostics).
    static func rawExchange(path: String, send bytes: Data, lines: Int = 1, timeoutSec: Int = 3) -> String? {
        guard let fd = connectFd(path, timeoutSec: timeoutSec) else { return nil }
        defer { close(fd) }
        _ = writeAll(fd, bytes)
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buf.filter({ $0 == 0x0A }).count < lines {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buf.append(chunk, count: n)
        }
        guard buf.contains(0x0A) else { return nil }
        return String(decoding: buf, as: UTF8.self)
    }
}
