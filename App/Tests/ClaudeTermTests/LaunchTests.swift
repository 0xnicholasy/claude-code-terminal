import Foundation
import Testing
@testable import ClaudeTerm

struct LaunchTests {
    let id = "33333333-3333-4333-8333-333333333333"

    @Test func rejectsNonUUIDSessionIds() {
        let bad = ["", "abc", "../../etc/passwd", id + "; rm -rf /", id + " ", "$(whoami)", id.uppercased() + "x"]
        for b in bad {
            #expect(throws: LaunchError.invalidSessionID) {
                try ClaudeCommand.resume(id: b, cwd: "/tmp", executable: "/usr/bin/claude")
            }
            #expect(throws: LaunchError.invalidSessionID) {
                try ClaudeCommand.newSession(id: b, cwd: "/tmp", executable: "/usr/bin/claude")
            }
        }
    }

    @Test func argvIsExactAndCwdNeverEntersTheCommand() throws {
        let hostile = "/tmp/it's $(touch pwned) `x`; a b"
        let resume = try ClaudeCommand.resume(id: id, cwd: hostile, executable: "/usr/bin/claude")
        #expect(resume.argv == ["/usr/bin/claude", "--resume", id])
        #expect(resume.cwd == hostile)
        #expect(!resume.ghosttyCommand.contains("pwned"))
        #expect(resume.ghosttyCommand == "/usr/bin/claude --resume \(id)")

        let fresh = try ClaudeCommand.newSession(id: id, cwd: "/tmp", executable: "/usr/bin/claude")
        #expect(fresh.arguments == ["--session-id", id])
    }

    @Test func refusesExecutablePathsThatCannotBeExpressedWithoutAShell() {
        for exe in ["claude", "/Users/a b/claude", "/tmp/x;rm", "/tmp/$(x)/claude", "/tmp/it's/claude"] {
            #expect(throws: LaunchError.unsupportedExecutablePath) {
                try ClaudeCommand.resume(id: id, cwd: "/tmp", executable: exe)
            }
        }
    }

    @Test func locatorPrefersEnvOverrideThenShellThenLocalBin() {
        func loc(env: [String: String], shell: String?, exec: Set<String>) -> String? {
            ClaudeLocator(environment: env, home: "/h", shellLookup: { shell }, isExecutable: { exec.contains($0) }).resolve()
        }
        let all: Set = ["/env/claude", "/shell/claude", "/h/.local/bin/claude"]
        #expect(loc(env: ["CCTERM_CLAUDE_PATH": "/env/claude"], shell: "/shell/claude", exec: all) == "/env/claude")
        #expect(loc(env: [:], shell: "/shell/claude", exec: all) == "/shell/claude")
        #expect(loc(env: [:], shell: nil, exec: all) == "/h/.local/bin/claude")
        #expect(loc(env: [:], shell: nil, exec: []) == nil)
    }
}

struct InheritedSessionEnvTests {
    @Test func removesSessionMarkersButKeepsUserKnobs() {
        let env = [
            "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "x",
            "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "3", "PATH": "/usr/bin", "HOME": "/Users/u",
        ]
        #expect(InheritedSessionEnv.toRemove(from: env) == ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID"])
    }
}
