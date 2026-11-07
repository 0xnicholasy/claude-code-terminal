import CCProtocol
import Foundation

/// A feed of the current session list. `AgentsPollingSource` polls the CLI; a socket-backed
/// source can be added later behind the same protocol.
protocol SessionSource: Sendable {
    func updates() -> AsyncStream<[SessionInfo]>
}

enum ProcessRunner {
    /// Runs an executable with an argv array and returns stdout, or nil on failure or timeout.
    /// Only ever used for read-only commands (`claude agents --json`, `ps`).
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                // Process is not Sendable; it is created here and only touched by this block and its
                // timeout item, which only reads isRunning and calls terminate on our own child.
                nonisolated(unsafe) let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = FileHandle.nullDevice
                proc.standardInput = FileHandle.nullDevice
                do { try proc.run() } catch {
                    cont.resume(returning: nil)
                    return
                }
                let pid = proc.processIdentifier
                let killer = DispatchWorkItem {
                    guard proc.isRunning else { return }
                    proc.terminate()
                    // Our own child: escalate if it ignores SIGTERM, so the pipe read below returns.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if proc.isRunning { kill(pid, SIGKILL) } }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killer.cancel()
                cont.resume(returning: proc.terminationStatus == 0 ? data : nil)
            }
        }
    }
}

struct AgentsPollingSource: SessionSource {
    let claude: ClaudeBinary
    var interval: TimeInterval = 5

    func updates() -> AsyncStream<[SessionInfo]> {
        let claude = claude
        let interval = interval
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    if let list = await Self.snapshot(claude: claude) { continuation.yield(list) }
                    try? await Task.sleep(for: .seconds(interval))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func snapshot(claude: ClaudeBinary) async -> [SessionInfo]? {
        guard let path = claude.get(),
              let json = await ProcessRunner.run(path, ["agents", "--json"]) else { return nil }
        let ps = await ProcessRunner.run("/bin/ps", ["-axo", "pid=,ppid=,rss="]) ?? Data()
        return try? build(agentsJSON: json, psOutput: String(decoding: ps, as: UTF8.self))
    }

    /// Pure: decode the agents payload and attach tree RSS from a ps table.
    static func build(agentsJSON: Data, psOutput: String) throws -> [SessionInfo] {
        let table = ProcessTable(psOutput: psOutput)
        return try AgentsDecoder.decode(agentsJSON).map { $0.sessionInfo(table: table) }
    }
}
