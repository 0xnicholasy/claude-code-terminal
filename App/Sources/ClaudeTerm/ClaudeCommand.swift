import CCProtocol
import Foundation

enum LaunchError: Error, Equatable {
    case invalidSessionID
    case invalidCwd
    case unsupportedExecutablePath
    case claudeNotFound
}

/// What a pane executes: an argv (never a shell string) plus a working directory.
struct LaunchSpec: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let cwd: String

    var argv: [String] { [executable] + arguments }

    /// Command string handed to the libghostty exec backend. It carries only the validated
    /// executable path, fixed flags and a UUID; cwd travels separately as the working directory.
    var ghosttyCommand: String { "direct:" + argv.joined(separator: " ") }
}

enum ClaudeCommand {
    static func newSession(id: String, cwd: String, executable: String) throws -> LaunchSpec {
        try make(["--session-id", id], id: id, cwd: cwd, executable: executable)
    }

    static func resume(id: String, cwd: String, executable: String) throws -> LaunchSpec {
        try make(["--resume", id], id: id, cwd: cwd, executable: executable)
    }

    private static func make(_ flags: [String], id: String, cwd: String, executable: String) throws -> LaunchSpec {
        guard SessionID.isValid(id) else { throw LaunchError.invalidSessionID }
        guard cwd.hasPrefix("/"), !cwd.contains("\0"), !cwd.contains("\n") else { throw LaunchError.invalidCwd }
        // The exec backend splits the command on whitespace, so a path with whitespace or quoting
        // characters cannot be expressed safely; refuse it rather than escape it.
        let unsafe = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"\\$`;&|<>()*?"))
        guard executable.hasPrefix("/"), executable.rangeOfCharacter(from: unsafe) == nil else {
            throw LaunchError.unsupportedExecutablePath
        }
        return LaunchSpec(executable: executable, arguments: flags, cwd: cwd)
    }
}

/// Resolves the claude binary: `CCTERM_CLAUDE_PATH`, then the login-shell `command -v claude`,
/// then `~/.local/bin/claude`. GUI apps do not inherit the login PATH.
struct ClaudeLocator: Sendable {
    var environment: [String: String]
    var home: String
    var shellLookup: @Sendable () -> String?
    var isExecutable: @Sendable (String) -> Bool

    static let live = ClaudeLocator(
        environment: ProcessInfo.processInfo.environment,
        home: NSHomeDirectory(),
        shellLookup: { loginShellLookup() },
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
    )

    func resolve() -> String? {
        if let p = environment["CCTERM_CLAUDE_PATH"], isExecutable(p) { return p }
        if let p = shellLookup(), isExecutable(p) { return p }
        let fallback = home + "/.local/bin/claude"
        return isExecutable(fallback) ? fallback : nil
    }

    private static func loginShellLookup() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).last.map(String.init)
    }
}

/// Resolves once, lazily, and caches. The lock guards the cached optional.
final class ClaudeBinary: @unchecked Sendable {
    private let locator: ClaudeLocator
    private let lock = NSLock()
    private var resolved = false
    private var path: String?

    init(locator: ClaudeLocator = .live) { self.locator = locator }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if !resolved {
            path = locator.resolve()
            resolved = true
        }
        return path
    }
}
