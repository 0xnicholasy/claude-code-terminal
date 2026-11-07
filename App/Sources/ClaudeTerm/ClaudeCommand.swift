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

    /// Command string handed to the libghostty exec backend. libghostty runs it as
    /// `/bin/bash -c "exec -l <command>"` (verified live 2026-11-07; the `direct:` prefix is not
    /// honoured), so it may only contain shell-inert characters: the validated executable path,
    /// fixed flags and a UUID. cwd travels separately as the working directory.
    var ghosttyCommand: String { argv.joined(separator: " ") }
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
        // libghostty shell-parses the command (bash -c "exec -l ..."), so the path may only use characters
        // that are inert in bash: an allowlist, not a denylist (braces, tildes, globs all expand).
        let inert = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/+@-")
        guard executable.hasPrefix("/"), executable.unicodeScalars.allSatisfy({ inert.contains($0) }) else {
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

/// Environment markers that belong to the Claude session that launched this app (e.g. when it is
/// started from a terminal inside Claude Code). A pane's claude inheriting them believes it is a
/// child session and turns transcript saving off (seen live 2026-11-07), so they are removed from
/// the app's own environment before any pane spawns. User-set knobs (CLAUDE_CODE_MAX_*, etc.) stay.
enum InheritedSessionEnv {
    static let names: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_PLUGIN_DATA", "AI_AGENT",
    ]

    static func toRemove(from environment: [String: String]) -> [String] {
        environment.keys.filter { names.contains($0) }.sorted()
    }

    static func scrubProcessEnvironment() {
        for name in toRemove(from: ProcessInfo.processInfo.environment) { unsetenv(name) }
    }
}

/// Apps started from Finder, Launchpad or `open` get launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`),
/// so hooks in a pane's claude that call `node`, `python3` or `bun` fail with "command not found"
/// (seen live 2026-11-07). The app adopts the login shell's PATH before any pane spawns.
enum LoginPath {
    static let marker = "__CCTERM_PATH__"

    /// Extracts the PATH printed between two markers, ignoring anything a profile prints around it.
    static func parse(_ output: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let path = parts[parts.count - 2].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && !path.contains("\n") ? path : nil
    }

    /// Login PATH first; entries of the current PATH that it lacks are kept at the end.
    static func merge(login: String?, current: String, fallback: [String]) -> String {
        var seen = Set<String>()
        let base = login.map { $0.split(separator: ":").map(String.init) } ?? fallback
        let all = base + current.split(separator: ":").map(String.init)
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Runs `zsh -l` with a 5 s cap; a hung profile must not hold up launch.
    static func lookup(timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf '%s%s%s' \(marker) \"$PATH\" \(marker)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func adopt() {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = NSHomeDirectory()
        let fallback = ["\(home)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                        "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        setenv("PATH", merge(login: lookup(), current: current, fallback: fallback), 1)
    }
}
