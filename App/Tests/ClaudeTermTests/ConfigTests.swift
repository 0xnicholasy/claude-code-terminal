import Foundation
import Testing
@testable import ClaudeTerm

struct ConfigTests {
    let secret = "sk-test-SECRET-4242"

    /// A temp home and project with one item per scope.
    func fixture() throws -> (home: String, project: String, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccterm-config-\(UUID().uuidString)").path
        let home = root + "/home", project = root + "/proj"
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try write(home + "/.claude/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: \"Ships it\"\n---\nbody")
        try write(home + "/.claude/skills/nameless/SKILL.md", "---\ndescription: >\n  Folded\n  text\n---\n")
        try write(home + "/.claude/skills/bare/SKILL.md", "no front matter")
        try write(home + "/.claude/agents/reviewer.md", "---\nname: reviewer\ndescription: Reviews code\n---\n")
        try write(project + "/.claude/skills/local-skill/SKILL.md", "---\nname: local-skill\ndescription: Project skill\n---\n")
        try write(project + "/.claude/agents/helper.md", "---\ndescription: Helps\n---\n")
        let plugin = home + "/.claude/plugins/cache/mkt/tool/1.0"
        try write(plugin + "/skills/plug/SKILL.md", "---\nname: plug\ndescription: From a plugin\n---\n")
        try write(home + "/.claude/plugins/cache/mkt/tool/0.9/skills/old/SKILL.md", "---\nname: old\n---\n")
        try write(home + "/.claude/plugins/installed_plugins.json", """
        {"version": 2, "plugins": {
          "tool@mkt": [{"scope": "user", "installPath": "\(plugin)"}],
          "other@mkt": [{"scope": "project", "projectPath": "/elsewhere", "installPath": "\(home)/.claude/plugins/cache/mkt/tool/0.9"}]
        }}
        """)
        try write(home + "/.claude/settings.json", """
        {"env": {"API_KEY": "\(secret)"}, "model": "opus",
         "hooks": {"PostToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "fmt.sh"}]}],
                   "Stop": [{"hooks": [{"type": "command", "command": "done.sh"}]}]}}
        """)
        try write(project + "/.claude/settings.json", "{\"hooks\": {\"PreToolUse\": [{\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"guard.sh\"}]}]}}")
        try write(project + "/.claude/settings.local.json", "{\"env\": {\"TOKEN\": \"\(secret)\"}, \"hooks\": {")
        try write(project + "/.env", "TOKEN=\(secret)")
        return (home, project, { try? FileManager.default.removeItem(atPath: root) })
    }

    @Test func eachScopeIsFoundAndLabelled() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let items = ConfigScanner.scan(home: f.home, project: f.project)
        func find(_ kind: ConfigItem.Kind, _ name: String) -> ConfigItem? { items.first { $0.kind == kind && $0.name == name } }
        #expect(find(.skill, "deploy")?.scope == .user)
        #expect(find(.skill, "local-skill")?.scope == .project)
        #expect(find(.skill, "plug")?.scope == .plugin)
        #expect(find(.skill, "old") == nil) // a cached version not installed for this project
        #expect(find(.agent, "reviewer")?.scope == .user)
        #expect(find(.agent, "helper")?.scope == .project)
        #expect(find(.hook, "PostToolUse")?.scope == .user)
        #expect(find(.hook, "PostToolUse")?.detail == "Edit|Write -> fmt.sh")
        #expect(find(.hook, "Stop")?.detail == "* -> done.sh")
        #expect(find(.hook, "PreToolUse")?.scope == .project)
        #expect(find(.skill, "deploy")?.path == f.home + "/.claude/skills/deploy/SKILL.md")
    }

    @Test func frontMatterIsParsedWithAFallbackName() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let items = ConfigScanner.scan(home: f.home, project: nil)
        #expect(items.first { $0.name == "deploy" }?.detail == "Ships it")
        #expect(items.first { $0.name == "nameless" }?.detail == "Folded text")
        #expect(items.first { $0.name == "bare" }?.detail == "")
        #expect(items.contains { $0.kind == .agent && $0.name == "reviewer" && $0.detail == "Reviews code" })
        // No project: project and local scopes are not scanned.
        #expect(!items.contains { $0.scope == .project || $0.scope == .local })
    }

    @Test func garbledSettingsGiveOneUnreadableRow() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let local = ConfigScanner.scan(home: f.home, project: f.project).filter { $0.scope == .local }
        #expect(local.count == 1)
        #expect(local.first?.unreadable == true)
        #expect(local.first?.detail == ConfigScanner.unreadableDetail)
    }

    @Test func secretsInEnvNeverReachTheOutput() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let items = ConfigScanner.scan(home: f.home, project: f.project)
        #expect(!items.isEmpty)
        for item in items {
            for text in [item.name, item.detail, item.path, item.id] { #expect(!text.contains(self.secret)) }
            #expect(!item.path.hasSuffix("/.env"))
        }
    }

    @Test func guardRefusesEnvFiles() throws {
        let f = try fixture()
        defer { f.cleanup() }
        #expect(!ConfigScanner.isAllowed("/p/.env"))
        #expect(!ConfigScanner.isAllowed("/p/.env.local"))
        #expect(!ConfigScanner.isAllowed("/p/.ENV"))
        #expect(ConfigScanner.isAllowed("/p/.claude/settings.json"))
        #expect(ConfigScanner.read(f.project + "/.env") == nil)
    }

    @Test func guardFollowsSymlinksToEnvFiles() throws {
        let f = try fixture()
        defer { f.cleanup() }
        try "---\nname: LEAKED\ndescription: \(secret)\n---\n".write(toFile: f.project + "/.env", atomically: true, encoding: .utf8)
        let skill = f.home + "/.claude/skills/sneaky"
        try FileManager.default.createDirectory(atPath: skill, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: skill + "/SKILL.md", withDestinationPath: f.project + "/.env")
        try FileManager.default.createSymbolicLink(atPath: f.home + "/.claude/agents/sneaky.md", withDestinationPath: f.project + "/.env")
        let items = ConfigScanner.scan(home: f.home, project: f.project)
        #expect(!items.contains { $0.name == "LEAKED" || $0.detail.contains(self.secret) })
        #expect(items.first { $0.kind == .skill && $0.name == "sneaky" }?.unreadable == true)
    }

    @Test func frontMatterHandlesCRLFAndBlankLinesInBlocks() {
        #expect(ConfigScanner.frontMatter("---\r\nname: a\r\ndescription: d\r\n---\r\nbody") == ["name": "a", "description": "d"])
        #expect(ConfigScanner.frontMatter("---\ndescription: >\n  a\n\n  b\nname: n\n---\n") == ["description": "a b", "name": "n"])
    }

    @Test func projectPluginsMatchTheProjectAndKeepEveryEntry() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let projPlugin = f.home + "/.claude/plugins/cache/mkt/tool/2.0"
        try FileManager.default.createDirectory(atPath: projPlugin + "/skills/projplug", withIntermediateDirectories: true)
        try "---\nname: projplug\n---\n".write(toFile: projPlugin + "/skills/projplug/SKILL.md", atomically: true, encoding: .utf8)
        try """
        {"plugins": {"tool@mkt": [
          {"scope": "user", "installPath": "\(f.home)/.claude/plugins/cache/mkt/tool/1.0"},
          {"scope": "project", "projectPath": "\(f.project)/", "installPath": "\(projPlugin)"}]}}
        """.write(toFile: f.home + "/.claude/plugins/installed_plugins.json", atomically: true, encoding: .utf8)
        let names = Set(ConfigScanner.skills(home: f.home, project: f.project).filter { $0.scope == .plugin }.map(\.name))
        #expect(names == ["plug", "projplug"])
        #expect(Set(ConfigScanner.skills(home: f.home, project: nil).filter { $0.scope == .plugin }.map(\.name)) == ["plug"])
    }

    @Test func oneOddHookFieldDoesNotHideTheFile() throws {
        let f = try fixture()
        defer { f.cleanup() }
        try "{\"hooks\": {\"Stop\": [{\"matcher\": 5, \"hooks\": [{\"type\": \"command\", \"command\": \"ok.sh\"}]}]}}"
            .write(toFile: f.project + "/.claude/settings.json", atomically: true, encoding: .utf8)
        let rows = ConfigScanner.hooks(home: f.home, project: f.project).filter { $0.scope == .project }
        #expect(rows.map(\.detail) == ["* -> ok.sh"])
    }

    // MARK: claude mcp list (T21)

    /// From one real `claude mcp list` run (Claude Code 2.1.322, 2026-11-13), with every command,
    /// argument and URL replaced by a placeholder. The `broken` row is added to cover a failure.
    static let mcpFixture = """
    Checking MCP server health\u{2026}

    claude.ai Claude Docs: https://placeholder.invalid/docs-SECRETURL - \u{2714} Connected
    plugin:vercel:vercel: https://placeholder.invalid/vercel?token=SECRETARG (HTTP) - ! Needs authentication
    github: npx -y placeholder-github-server --token SECRETARG - \u{2714} Connected
    linear: https://placeholder.invalid/linear/sse (SSE) - ! Needs authentication
    broken: node /placeholder/server.js - --flag SECRETARG - \u{2717} Failed to connect
    dashed: run --mode - needs auth fallback SECRETARG - \u{2714} Connected
    odd: something - mystery state
    this line has no separator
    https://placeholder.invalid/x?token=SECRETARG: junk - \u{2714} Connected
    --token SECRETARG: wrapped - \u{2714} Connected
    """

    @Test func mcpFixtureParsesNamesAndStatuses() {
        let servers = McpList.parse(Self.mcpFixture)
        #expect(servers.map(\.name) == ["claude.ai Claude Docs", "plugin:vercel:vercel", "github", "linear", "broken", "dashed", "odd"])
        #expect(servers.map(\.status) == [.connected, .needsAuth, .connected, .needsAuth, .failed, .connected, .unknown])
        #expect(servers.filter(\.isPlugin).map(\.name) == ["plugin:vercel:vercel"])
        // The header, the blank line and the line without separators are skipped.
        #expect(!servers.contains { $0.name.contains("Checking") || $0.name.contains("no separator") })
    }

    @Test func mcpRowsKeepNoArgumentOrURL() {
        for s in McpList.parse(Self.mcpFixture) {
            for text in [s.name, s.id, s.status.rawValue] {
                #expect(!text.contains("SECRET"))
                #expect(!text.contains("placeholder"))
                #expect(!text.contains("://"))
            }
        }
    }

    @Test func mcpScopeComesFromServerNamesOnly() throws {
        let f = try fixture()
        defer { f.cleanup() }
        try "{\"mcpServers\": {\"proj-server\": {\"command\": \"x\", \"env\": {\"K\": \"\(secret)\"}}}}"
            .write(toFile: f.project + "/.mcp.json", atomically: true, encoding: .utf8)
        try "{\"numStartups\": 3, \"mcpServers\": {\"github\": {\"args\": [\"\(secret)\"]}}}"
            .write(toFile: f.home + "/.claude.json", atomically: true, encoding: .utf8)
        #expect(McpList.scope(of: "proj-server", home: f.home, project: f.project) == .project)
        #expect(McpList.scope(of: "github", home: f.home, project: f.project) == .user)
        #expect(McpList.scope(of: "plugin:a:b", home: f.home, project: f.project) == .plugin)
        #expect(McpList.scope(of: "claude.ai Gmail", home: f.home, project: f.project) == nil)
    }

    @Test @MainActor func mcpTimeoutGivesAnErrorStateAndRefreshReruns() async {
        let calls = Counter()
        let model = McpListModel(home: "/nonexistent", claudePath: { "/usr/bin/claude-fake" }, runner: { _, args, cwd, _ in
            await calls.add("\(cwd) \(args.joined(separator: " "))")
            return nil // what the runner returns after its timeout kills the process
        })
        await model.load(project: "/p")
        #expect(model.states["/p"] == .failed(McpListModel.failedText))
        await model.load(project: "/p")
        #expect(await calls.items == ["/p mcp list"]) // cached: not run again
        await model.load(project: "/p", force: true)
        #expect(await calls.items.count == 2)
    }

    @Test @MainActor func mcpLoadCachesParsedRowsPerProject() async {
        let fixture = Data(Self.mcpFixture.utf8)
        let model = McpListModel(home: "/nonexistent", claudePath: { "/usr/bin/claude-fake" }, runner: { _, _, _, _ in fixture })
        await model.load(project: "/p")
        guard case let .loaded(rows) = model.states["/p"] else {
            Issue.record("not loaded")
            return
        }
        #expect(rows.count == 7)
        #expect(rows.first { $0.isPlugin }?.scope == .plugin)
        #expect(model.states["/q"] == nil)
    }

    @Test @MainActor func mcpLoadInFlightIsNotStartedTwice() async {
        let calls = Counter()
        let model = McpListModel(home: "/nonexistent", claudePath: { "/usr/bin/claude-fake" }, runner: { _, _, _, _ in
            await calls.add("run")
            try? await Task.sleep(for: .milliseconds(300))
            return Data()
        })
        async let first: Void = model.load(project: "/p")
        try? await Task.sleep(for: .milliseconds(50))
        await model.load(project: "/p", force: true)
        await first
        #expect(await calls.items.count == 1)
        #expect(model.states["/p"] == .loaded([]))
    }

    @Test func mcpRunnerReturnsWhileAGrandchildHoldsThePipe() async {
        let start = Date()
        let out = await McpList.run("/bin/sh", ["-c", "sleep 8 & echo hi"], cwd: "/tmp", timeout: 5)
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == "hi\n")
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func mcpRunnerStopsAHungCommand() async {
        let start = Date()
        let out = await McpList.run("/bin/sleep", ["10"], cwd: "/tmp", timeout: 0.5)
        #expect(out == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(await McpList.run("/bin/pwd", [], cwd: "/usr", timeout: 5).map { String(decoding: $0, as: UTF8.self) } == "/usr\n")
    }

    @Test func readRefusesNonRegularAndOversizedFiles() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let fifo = f.home + "/.claude/skills/fifo"
        try FileManager.default.createDirectory(atPath: fifo, withIntermediateDirectories: true)
        #expect(mkfifo(fifo + "/SKILL.md", 0o600) == 0)
        let big = f.home + "/.claude/agents/big.md"
        try Data(count: ConfigScanner.maxFileBytes + 1).write(to: URL(fileURLWithPath: big))
        let device = f.home + "/.claude/agents/device.md"
        try FileManager.default.createSymbolicLink(atPath: device, withDestinationPath: "/dev/null")
        #expect(ConfigScanner.read(device) == nil)
        #expect(ConfigScanner.read(fifo + "/SKILL.md") == nil)
        #expect(ConfigScanner.read(big) == nil)
        let items = ConfigScanner.scan(home: f.home, project: f.project) // returns instead of blocking on the FIFO
        #expect(items.first { $0.name == "fifo" }?.unreadable == true)
    }
}

actor Counter {
    private(set) var items: [String] = []
    func add(_ s: String) { items.append(s) }
}
