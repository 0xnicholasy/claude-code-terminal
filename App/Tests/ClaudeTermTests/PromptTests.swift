import CCProtocol
import Foundation
import GhosttyTerminal
import Testing
@testable import ClaudeTerm

struct PromptTests {
    static let cwd = "/w/a"

    static func status(_ tools: [(String, String)]) -> TranscriptStatus {
        TranscriptStatus(pending: tools.map { .init(id: $0.0, name: $0.1, summary: $0.1, detail: "ls") })
    }

    static func tool(_ name: String, _ detail: String?) -> TranscriptStatus.PendingTool {
        .init(id: "t1", name: name, summary: name, detail: detail)
    }

    static func eligible(_ name: String, _ detail: String?, cwd: String = cwd) -> Bool {
        PromptAnswer.eligible(TranscriptStatus(pending: [tool(name, detail)]), cwd: cwd) != nil
    }

    @Test func allowPressesOneAndDenyPressesEscape() {
        #expect(PromptAnswer.keys(allow: true) == .digit1)
        #expect(PromptAnswer.keys(allow: false) == .escape)
    }

    @Test func singlePlainToolIsEligible() {
        #expect(PromptAnswer.eligible(Self.status([("t1", "Bash")]), cwd: Self.cwd)?.id == "t1")
    }

    @Test func twoPendingToolsAreNotEligible() {
        #expect(PromptAnswer.eligible(Self.status([("t1", "Bash"), ("t2", "Edit")]), cwd: Self.cwd) == nil)
        #expect(PromptAnswer.eligible(Self.status([]), cwd: Self.cwd) == nil)
    }

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode", "Task", "Agent"])
    func excludedToolIsNotEligible(name: String) {
        // Short Bash-like text, so only the tool name stands in the way.
        let status = TranscriptStatus(pending: [.init(id: "t1", name: name, summary: name, detail: "ls")])
        #expect(PromptAnswer.eligible(status, cwd: Self.cwd) == nil)
    }

    @Test func canSendOnlyForTheShownToolWhileBlockedWithAProcess() {
        let s = Self.status([("t1", "Bash")])
        #expect(PromptAnswer.canSend(state: .blocked, shownToolUseId: "t1", current: s, hasProcess: true, cwd: Self.cwd))
        #expect(!PromptAnswer.canSend(state: .running, shownToolUseId: "t1", current: s, hasProcess: true, cwd: Self.cwd))
        #expect(!PromptAnswer.canSend(state: .blocked, shownToolUseId: "t0", current: s, hasProcess: true, cwd: Self.cwd))
        #expect(!PromptAnswer.canSend(state: .blocked, shownToolUseId: "t1", current: s, hasProcess: false, cwd: Self.cwd))
        #expect(!PromptAnswer.canSend(state: .blocked, shownToolUseId: "t1", current: nil, hasProcess: true, cwd: Self.cwd))
    }

    @Test func bashCommandIsShownWholeOnlyWhenShortAndSingleLine() {
        let sixty = String(repeating: "x", count: 60)
        #expect(Self.eligible("Bash", sixty))
        #expect(PromptAnswer.label(Self.tool("Bash", sixty), cwd: Self.cwd) == "Bash: " + sixty)
        #expect(!Self.eligible("Bash", sixty + "x"))
        #expect(!Self.eligible("Bash", "echo a\necho b"))
        // Trailing whitespace and newlines are not part of the command.
        #expect(Self.eligible("Bash", "ls\n"))
        #expect(!Self.eligible("Bash", nil))
    }

    @Test func fileToolIsShownProjectRelativeOnlyInsideTheProject() {
        #expect(PromptAnswer.label(Self.tool("Edit", "/w/a/src/main.swift"), cwd: Self.cwd) == "Edit src/main.swift")
        #expect(Self.eligible("Write", "/w/a/new.txt"))
        #expect(Self.eligible("NotebookEdit", "/w/a/nb.ipynb"))
        #expect(!Self.eligible("Edit", "/w/other/main.swift"))
        #expect(!Self.eligible("Edit", "/w/a/../other/main.swift"))
        #expect(!Self.eligible("Edit", "/w/ab/main.swift"))
        #expect(!Self.eligible("Edit", "/w/a"))
        #expect(!Self.eligible("Edit", "main.swift"))
        #expect(!Self.eligible("Read", nil))
    }

    @Test func projectMatchesThroughSymlinks() throws {
        let fm = FileManager.default
        let dir = "/tmp/claudeterm-prompt-\(UUID().uuidString)"
        try fm.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        // On macOS /tmp is a symlink to /private/tmp.
        #expect(Self.eligible("Edit", "/private" + dir + "/src/a.swift", cwd: dir))
        #expect(PromptAnswer.label(Self.tool("Edit", dir + "/src/a.swift"), cwd: "/private" + dir) == "Edit src/a.swift")
        // A symlink inside the project that points outside it does not count as inside.
        try fm.createSymbolicLink(atPath: dir + "/escape", withDestinationPath: "/etc")
        #expect(!Self.eligible("Edit", dir + "/escape/hosts", cwd: dir))
    }

    @Test(arguments: ["WebFetch", "mcp__x__y", "Grep", "Task"])
    func otherToolsAreNeverShownWhole(name: String) {
        #expect(!Self.eligible(name, "/w/a/file"))
        #expect(PromptAnswer.label(Self.tool(name, "ls"), cwd: Self.cwd) == nil)
    }

    @Test func bashCommandWithHiddenCharactersIsNotShownWhole() {
        #expect(!Self.eligible("Bash", "ls \u{202E}gpj.txt"))
        #expect(!Self.eligible("Bash", "ls\u{200B}x"))
        #expect(!Self.eligible("Bash", "ls \u{1B}[2Jx"))
        #expect(!Self.eligible("Bash", "ls\u{0}x"))
        // 51 scalars but one grapheme-sized run: counted by scalar, and not plain ASCII anyway.
        #expect(!Self.eligible("Bash", "e" + String(repeating: "\u{0301}", count: 50)))
        // Scalars are counted, so 61 plain characters stay refused.
        #expect(!Self.eligible("Bash", String(repeating: "x", count: 61)))
    }

    @Test func fileLabelWithHiddenCharactersIsRefused() {
        #expect(!Self.eligible("Edit", "/w/a/x\u{202E}gpj.txt"))
        #expect(!Self.eligible("Edit", "/w/a/x\ny.txt"))
        #expect(Self.eligible("Edit", "/w/a/x y.txt"))
    }

    @Test func projectRootMustBeAbsoluteAndNarrowEnough() {
        #expect(!Self.eligible("Edit", "/w/a/x.txt", cwd: "/"))
        #expect(!Self.eligible("Edit", NSHomeDirectory() + "/x.txt", cwd: NSHomeDirectory()))
        #expect(!Self.eligible("Edit", "/w/a/x.txt", cwd: "w/a"))
        #expect(!Self.eligible("Edit", "/w/a/x.txt", cwd: ""))
    }

    @Test func pathWithDotDotComponentIsRefused() {
        #expect(!Self.eligible("Edit", "/w/a/sub/../x.txt"))
        #expect(!Self.eligible("Edit", "/w/a/x.txt", cwd: "/w/a/sub/.."))
    }

    @Test func danglingSymlinkOutsideTheProjectIsRefused() throws {
        let fm = FileManager.default
        let dir = "/tmp/claudeterm-prompt-\(UUID().uuidString)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        try fm.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "/tmp/claudeterm-missing-\(UUID().uuidString)/x")
        #expect(!Self.eligible("Write", dir + "/link", cwd: dir))
        #expect(Self.eligible("Write", dir + "/fresh.txt", cwd: dir))
    }
}
