import Foundation

/// Where a config item was found. `local` is `<project>/.claude/settings.local.json` only.
enum ConfigScope: String, Equatable, Sendable {
    case user, project, local, plugin
}

/// One row of the Config tab (T22): a skill, an agent or a hook, or a file that could not be read.
struct ConfigItem: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable { case skill, agent, hook }

    var kind: Kind
    var name: String
    var detail: String
    var scope: ConfigScope
    var path: String
    var unreadable = false

    var id: String { "\(kind.rawValue)|\(scope.rawValue)|\(path)|\(name)|\(detail)" }
}

/// Reads skills, agents and hooks for one project. Pure apart from file reads: home and project
/// paths are passed in. Read-only (D3): `.env` files are never opened, and settings files are decoded
/// for their `hooks` key only, so `env` values are never decoded.
enum ConfigScanner {
    static let unreadableDetail = "Could not read this file"

    static func scan(home: String, project: String?) -> [ConfigItem] {
        skills(home: home, project: project) + agents(home: home, project: project) + hooks(home: home, project: project)
    }

    // MARK: Skills and agents

    static func skills(home: String, project: String?) -> [ConfigItem] {
        var out = skillDirs(home + "/.claude/skills", scope: .user)
        if let project { out += skillDirs(project + "/.claude/skills", scope: .project) }
        for root in pluginRoots(home: home, project: project) {
            out += skillDirs(root + "/skills", scope: .plugin)
        }
        return out
    }

    static func agents(home: String, project: String?) -> [ConfigItem] {
        var out = agentFiles(home + "/.claude/agents", scope: .user)
        if let project { out += agentFiles(project + "/.claude/agents", scope: .project) }
        return out
    }

    private static func skillDirs(_ dir: String, scope: ConfigScope) -> [ConfigItem] {
        children(of: dir).compactMap { name -> ConfigItem? in
            let path = dir + "/" + name + "/SKILL.md"
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return described(.skill, path: path, fallback: name, scope: scope)
        }
    }

    private static func agentFiles(_ dir: String, scope: ConfigScope) -> [ConfigItem] {
        children(of: dir).filter { $0.hasSuffix(".md") }.map { file in
            described(.agent, path: dir + "/" + file, fallback: String(file.dropLast(3)), scope: scope)
        }
    }

    private static func described(_ kind: ConfigItem.Kind, path: String, fallback: String, scope: ConfigScope) -> ConfigItem {
        guard let text = read(path) else {
            return ConfigItem(kind: kind, name: fallback, detail: unreadableDetail, scope: scope, path: path, unreadable: true)
        }
        let meta = frontMatter(text)
        let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return ConfigItem(kind: kind, name: name, detail: meta["description"] ?? "", scope: scope, path: path)
    }

    /// Install folders of the plugins Claude Code has installed for the user, or for this project
    /// (`~/.claude/plugins/installed_plugins.json`). A plain `~/.claude/plugins/**/skills` walk would
    /// also list every cached old version and uninstalled marketplace copy (D13, amended by T20).
    static func pluginRoots(home: String, project: String?) -> [String] {
        struct Installed: Decodable {
            struct Entry: Decodable {
                var scope: String?
                var installPath: String?
                var projectPath: String?
            }
            var plugins: [String: [Entry]]
        }
        guard let data = read(home + "/.claude/plugins/installed_plugins.json").map({ Data($0.utf8) }),
              let installed = try? JSONDecoder().decode(Installed.self, from: data) else { return [] }
        let here = project.map(canonical)
        var seen = Set<String>()
        return installed.plugins.keys.sorted().flatMap { key in
            (installed.plugins[key] ?? []).filter { e in
                e.scope == "user" || (e.scope == "project" && here != nil && e.projectPath.map(canonical) == here)
            }.compactMap(\.installPath)
        }.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    /// `key: value` pairs between the opening `---` and the next `---`. Quotes are stripped; a
    /// folded (`>`) or literal (`|`) value takes the indented lines that follow, joined by spaces.
    static func frontMatter(_ text: String) -> [String: String] {
        // "\r\n" is one Character in Swift, so normalise line ends before splitting.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(value) {
                var parts: [String] = []
                func indented(_ l: String) -> Bool { l.hasPrefix(" ") || l.hasPrefix("\t") }
                while i < lines.count {
                    // A blank line stays in the block while the next non-blank line is still indented.
                    if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        guard let next = lines[i...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                              indented(next) else { break }
                        i += 1
                        continue
                    }
                    guard indented(lines[i]) else { break }
                    parts.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                value = parts.joined(separator: " ")
            } else if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, out[key] == nil { out[key] = value }
        }
        return out
    }

    // MARK: Hooks

    /// Only the `hooks` key is declared, so `JSONDecoder` never decodes `env` or anything else.
    private struct HookSettings: Decodable {
        // Fields are read leniently: one value of an unexpected type drops that field, not the file.
        struct Group: Decodable {
            var matcher: String?
            var hooks: [Hook]?
            enum CodingKeys: String, CodingKey { case matcher, hooks }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                matcher = try? c.decodeIfPresent(String.self, forKey: .matcher)
                hooks = try? c.decodeIfPresent([Hook].self, forKey: .hooks)
            }
        }
        struct Hook: Decodable {
            var type: String?
            var command: String?
            enum CodingKeys: String, CodingKey { case type, command }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try? c.decodeIfPresent(String.self, forKey: .type)
                command = try? c.decodeIfPresent(String.self, forKey: .command)
            }
        }
        var hooks: [String: [Group]]?
    }

    static func hooks(home: String, project: String?) -> [ConfigItem] {
        var files = [(home + "/.claude/settings.json", ConfigScope.user)]
        if let project {
            files += [(project + "/.claude/settings.json", .project), (project + "/.claude/settings.local.json", .local)]
        }
        return files.flatMap { path, scope -> [ConfigItem] in
            guard FileManager.default.fileExists(atPath: path) else { return [] }
            guard let text = read(path),
                  let settings = try? JSONDecoder().decode(HookSettings.self, from: Data(text.utf8)) else {
                return [ConfigItem(kind: .hook, name: (path as NSString).lastPathComponent, detail: unreadableDetail,
                                   scope: scope, path: path, unreadable: true)]
            }
            return (settings.hooks ?? [:]).keys.sorted().flatMap { event in
                (settings.hooks?[event] ?? []).flatMap { group in
                    let matcher = group.matcher.flatMap { $0.isEmpty ? nil : $0 } ?? "*"
                    return (group.hooks ?? []).map { hook in
                        ConfigItem(kind: .hook, name: event,
                                   detail: "\(matcher) -> \(hook.command ?? hook.type ?? "?")", scope: scope, path: path)
                    }
                }
            }
        }
    }

    // MARK: Files

    /// D3: no `.env` file is ever opened (`.env`, `.env.local`, `.ENV`, ...), also not through a
    /// symlink: the name is checked on the path as given and on the file it resolves to.
    static func isAllowed(_ path: String) -> Bool {
        func ok(_ p: String) -> Bool { !(p as NSString).lastPathComponent.lowercased().hasPrefix(".env") }
        return ok(path) && ok(canonical(path))
    }

    /// Largest file the scanner reads. `~/.claude.json` is the biggest it opens (about 0.6 MB here).
    static let maxFileBytes = 8 << 20

    /// Reads a regular file of at most `maxFileBytes`: a FIFO, device or huge file planted in a repo
    /// under a config name would otherwise block or bloat the scan.
    static func read(_ path: String) -> String? {
        guard isAllowed(path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: canonical(path)),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size <= maxFileBytes,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Symlinks resolved and `.`/`..`/trailing slashes removed, for comparing and guarding paths.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func children(of dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
}

// MARK: MCP servers (T21)

/// One `claude mcp list` row. Only the name and the health status are kept: the command, its
/// arguments and URLs are dropped at parse time, since they can carry tokens (D3).
struct McpServer: Equatable, Identifiable, Sendable {
    enum Status: String, Equatable, Sendable { case connected, failed, needsAuth, unknown }

    var name: String
    var status: Status
    var scope: ConfigScope?

    var id: String { name }
    var isPlugin: Bool { name.hasPrefix("plugin:") }
}

enum McpList {
    /// `<name>: <command or URL> - <symbol> <status>`. The name ends at the first `": "` and the
    /// status starts after the last `" - "`; anything between is never stored. Other lines (the
    /// "Checking MCP server health" header, blank lines, anything unexpected) are skipped.
    static func parse(_ output: String) -> [McpServer] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard let nameEnd = line.range(of: ": "),
                  let statusStart = line.range(of: " - ", options: .backwards),
                  nameEnd.upperBound <= statusStart.lowerBound else { return nil }
            let name = line[..<nameEnd.lowerBound].trimmingCharacters(in: .whitespaces)
            // Server names never hold "/" or "=", nor start with "-"; text that does is an argument,
            // a URL or a wrapped line, and is skipped rather than shown.
            guard !name.isEmpty, !name.contains("/"), !name.contains("="), !name.hasPrefix("-") else { return nil }
            return McpServer(name: name, status: status(String(line[statusStart.upperBound...])), scope: nil)
        }
    }

    static func status(_ text: String) -> McpServer.Status {
        let t = text.lowercased()
        if t.contains("needs auth") { return .needsAuth }
        if t.contains("fail") || t.contains("error") || t.contains("disconnected") { return .failed }
        if t.contains("connected") { return .connected }
        return .unknown
    }

    /// D12: `project` for names in `<project>/.mcp.json`, `user` for names in `~/.claude.json`'s
    /// top-level `mcpServers`, `plugin` for a `plugin:` prefix, else nil ("unknown"). Only the key
    /// names of `mcpServers` are decoded, never a server's command, arguments, URL or env.
    static func scope(of name: String, home: String, project: String?) -> ConfigScope? {
        if name.hasPrefix("plugin:") { return .plugin }
        if let project, serverNames(project + "/.mcp.json").contains(name) { return .project }
        if serverNames(home + "/.claude.json").contains(name) { return .user }
        return nil
    }

    private struct Names: Decodable {
        /// Decodes nothing, so a server's settings are never read into memory as values.
        struct Opaque: Decodable { init(from decoder: Decoder) throws {} }
        var mcpServers: [String: Opaque]?
    }

    /// Server names in `<project>/.mcp.json`, sorted. Check asks before running when this is not
    /// empty, because `claude mcp list` starts these servers too.
    static func projectServers(project: String) -> [String] {
        serverNames(project + "/.mcp.json").sorted()
    }

    static func serverNames(_ path: String) -> Set<String> {
        guard let text = ConfigScanner.read(path),
              let names = try? JSONDecoder().decode(Names.self, from: Data(text.utf8)) else { return [] }
        return Set((names.mcpServers ?? [:]).keys)
    }

    /// Runs a read-only command in `cwd` and returns stdout, or nil on a non-zero exit or after
    /// `timeout`. The result never waits for the pipe to close: an MCP server the command started can
    /// keep the inherited stdout open long after it exits, so output is collected as it arrives and
    /// the call returns at exit (plus a 1 s drain) or at the timeout, whichever comes first.
    static func run(_ executable: String, _ arguments: [String], cwd: String, timeout: TimeInterval) async -> Data? {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var finished = false
            let eof = DispatchSemaphore(value: 0)
            /// Runs `body` once; later calls are ignored.
            func finishOnce(_ body: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                body()
            }
            func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
            var snapshot: Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let box = Box()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice
            proc.standardInput = FileHandle.nullDevice
            let reader = out.fileHandleForReading
            reader.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty {
                    h.readabilityHandler = nil
                    box.eof.signal()
                } else {
                    box.append(d)
                }
            }
            let finish: @Sendable (Data?) -> Void = { result in
                box.finishOnce {
                    reader.readabilityHandler = nil
                    cont.resume(returning: result)
                }
            }
            proc.terminationHandler = { p in
                let ok = p.terminationReason == .exit && p.terminationStatus == 0
                DispatchQueue.global(qos: .utility).async {
                    _ = box.eof.wait(timeout: .now() + 1)
                    finish(ok ? box.snapshot : nil)
                }
            }
            do { try proc.run() } catch {
                finish(nil)
                return
            }
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(nil)
                // Our own child: stop it, escalating if it ignores SIGTERM.
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
            }
        }
    }
}

/// `claude mcp list` per project, cached by project path. It starts every server for a health
/// check, including servers from the project's `.mcp.json`, so it runs only when the user clicks
/// Check or Refresh in the Config tab, never when the tab opens.
@MainActor
final class McpListModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded([McpServer])
        case failed(String)
    }

    static let timeout: TimeInterval = 30
    static let failedText = "claude mcp list did not finish. Try Refresh."
    static let noClaudeText = "Could not find the claude binary."

    @Published private(set) var states: [String: State] = [:]
    private let home: String
    private let claudePath: @Sendable () -> String?
    private let runner: @Sendable (String, [String], String, TimeInterval) async -> Data?

    init(home: String = NSHomeDirectory(), claudePath: @escaping @Sendable () -> String?,
         runner: @escaping @Sendable (String, [String], String, TimeInterval) async -> Data? = {
             await McpList.run($0, $1, cwd: $2, timeout: $3)
         }) {
        self.home = home
        self.claudePath = claudePath
        self.runner = runner
    }

    /// Loads once per project; `force` (Refresh) re-runs. A load already in flight is not repeated.
    func load(project: String, force: Bool = false) async {
        if states[project] == .loading { return }
        if !force, states[project] != nil { return }
        guard let exe = claudePath() else {
            states[project] = .failed(Self.noClaudeText)
            return
        }
        states[project] = .loading
        let data = await runner(exe, ["mcp", "list"], project, Self.timeout)
        guard let data, let text = String(data: data, encoding: .utf8) else {
            states[project] = .failed(Self.failedText)
            return
        }
        let home = home
        let servers = await Task.detached {
            McpList.parse(text).map { s in
                var s = s
                s.scope = McpList.scope(of: s.name, home: home, project: project)
                return s
            }
        }.value
        states[project] = .loaded(servers)
    }
}
