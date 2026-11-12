import Foundation
import Testing
@testable import ClaudeTerm

struct TranscriptTests {
    static let lines = [
        #"{"type":"user","isSidechain":false,"uuid":"u1","timestamp":"2026-11-12T04:00:00.000Z","message":{"role":"user","content":"Fixture prompt"}}"#,
        #"{"type":"assistant","isSidechain":false,"uuid":"a1","timestamp":"2026-11-12T04:00:02.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo fixture","description":"Fixture command"},"caller":{"type":"direct"}}],"usage":{"input_tokens":2,"cache_read_input_tokens":40000,"cache_creation_input_tokens":500,"output_tokens":30}}}"#,
        #"{"type":"user","isSidechain":false,"uuid":"u2","timestamp":"2026-11-12T04:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"fixture output"}]}}"#,
        #"{"type":"assistant","isSidechain":true,"agentId":"agentfixture","uuid":"s1","timestamp":"2026-11-12T04:00:04.000Z","message":{"id":"msg_s","model":"claude-sonnet-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_s","name":"Read","input":{"file_path":"fixture.txt"},"caller":{"type":"direct"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":9000,"cache_creation_input_tokens":0,"output_tokens":12}}}"#,
        #"{"type":"assistant","isSidechain":false,"uuid":"a2","timestamp":"2026-11-12T04:00:06.000Z","message":{"id":"msg_2","model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_2","name":"Edit","input":{"file_path":"fixture.swift","old_string":"a","new_string":"b"},"caller":{"type":"direct"}}],"usage":{"input_tokens":1,"cache_read_input_tokens":210000,"cache_creation_input_tokens":1200,"output_tokens":80}}}"#,
        #"{"type":"system","subtype":"turn_duration","isSidechain":false,"uuid":"y1","timestamp":"2026-11-12T04:00:07.000Z","durationMs":7000}"#,
        #"{"type":"assistant","isSidechain":false,"message":{"model":"#,
        #"{"type":"user","isSidechain":false,"uuid":"u3","timestamp":"2026-11-12T04:00:09.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"denied","is_error":true}]}}"#,
    ]

    static func parse(_ range: Range<Int>) -> TranscriptStatus {
        TranscriptStatus.parse(Data(lines[range].joined(separator: "\n").utf8))
    }

    static func toolLine(id: String, name: String, input: String) -> String {
        #"{"type":"assistant","isSidechain":false,"message":{"id":"m","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    @Test func toolUseWithoutResultIsPending() {
        let s = Self.parse(0..<7)
        #expect(s.pending == [.init(id: "toolu_2", name: "Edit", summary: "Edit fixture.swift")])
        #expect(s.activity == "Edit fixture.swift")
    }

    @Test func toolResultCompletesTheToolUse() {
        #expect(Self.parse(0..<3).pending.isEmpty)
        #expect(Self.parse(0..<8).pending.isEmpty)
        #expect(Self.parse(0..<3).activity == nil)
    }

    @Test func parallelToolUsesStayPendingInOrder() {
        let data = Data([
            Self.toolLine(id: "t1", name: "Read", input: #"{"file_path":"/a/b.txt"}"#),
            Self.toolLine(id: "t2", name: "Bash", input: #"{"command":"ls"}"#),
        ].joined(separator: "\n").utf8)
        let s = TranscriptStatus.parse(data)
        #expect(s.pending.map(\.id) == ["t1", "t2"])
        #expect(s.activity == "Bash: ls")
    }

    @Test func newPromptClearsPendingTools() {
        let prompt = #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"next"}}"#
        let s = TranscriptStatus.parse(Data((Array(Self.lines[0..<5]) + [prompt]).joined(separator: "\n").utf8))
        #expect(s.pending.isEmpty)
        let wrapper = #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#
        let t = TranscriptStatus.parse(Data((Array(Self.lines[0..<5]) + [wrapper]).joined(separator: "\n").utf8))
        #expect(t.pending.map(\.id) == ["toolu_2"])
    }

    static func afterPending(_ line: String) -> TranscriptStatus {
        TranscriptStatus.parse(Data((Array(lines[0..<5]) + [line]).joined(separator: "\n").utf8))
    }

    @Test func textBlockPromptClearsPendingTools() {
        let s = Self.afterPending(#"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"go"}]}}"#)
        #expect(s.pending.isEmpty)
    }

    @Test func wrapperBlockBeforeRealPromptStillClears() {
        let both = Self.afterPending(#"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"},{"type":"text","text":"real"}]}}"#)
        #expect(both.pending.isEmpty)
        let only = Self.afterPending(#"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"}]}}"#)
        #expect(only.pending.map(\.id) == ["toolu_2"])
    }

    @Test func underscoreAndUppercaseWrappersAreNotPrompts() {
        for text in ["<ide_opened_file>a.swift</ide_opened_file>", "<Local-Command attr=1>x"] {
            let s = Self.afterPending(#"{"type":"user","isSidechain":false,"message":{"role":"user","content":"\#(text)"}}"#)
            #expect(s.pending.map(\.id) == ["toolu_2"])
        }
    }

    @Test func metaUserLineDoesNotClearPending() {
        let s = Self.afterPending(#"{"type":"user","isSidechain":false,"isMeta":true,"message":{"role":"user","content":"hi"}}"#)
        #expect(s.pending.map(\.id) == ["toolu_2"])
    }

    @Test func sidechainLinesAreIgnoredEntirely() {
        let s = Self.parse(3..<4)
        #expect(s.pending.isEmpty)
        #expect(s.contextTokens == nil)
        #expect(s.model == nil)
    }

    @Test func contextTokensSumInputAndCacheOfLastAssistantLine() {
        let s = Self.parse(0..<7)
        #expect(s.contextTokens == 211_201)
        #expect(s.model == "claude-opus-5-5")
        #expect(Self.parse(0..<2).contextTokens == 40_502)
    }

    @Test func syntheticModelIsSkippedForUsageAndModel() {
        let synthetic = #"{"type":"assistant","isSidechain":false,"message":{"model":"<synthetic>","content":[],"usage":{"input_tokens":0}}}"#
        let s = TranscriptStatus.parse(Data((Array(Self.lines[0..<2]) + [synthetic]).joined(separator: "\n").utf8))
        #expect(s.contextTokens == 40_502)
        #expect(s.model == "claude-opus-5-5")
    }

    @Test func contextLimitIs200KUntilUsageProves1M() {
        #expect(TranscriptStatus.contextLimit(model: "claude-opus-5-5", tokens: 200_000) == 200_000)
        #expect(TranscriptStatus.contextLimit(model: "claude-opus-5-5", tokens: 211_201) == 1_000_000)
    }

    @Test func contextHelpShowsTokensOfLimitAndPercent() {
        var s = TranscriptStatus()
        #expect(s.contextHelp == nil && s.contextFraction == nil)
        s.contextTokens = 132_000
        #expect(s.contextHelp == "Context: 132K of 200K (66%)")
        #expect(s.contextFraction == 0.66)
        s.contextTokens = 211_201
        #expect(s.contextHelp == "Context: 211.2K of 1M (21%)")
        s.contextTokens = 58_000
        #expect(s.contextHelp == "Context: 58K of 200K (29%)")
    }

    @Test func levelEdgesAt70And85Percent() {
        #expect(ContextLevel.of(0.6999) == .normal)
        #expect(ContextLevel.of(0.70) == .amber)
        #expect(ContextLevel.of(0.8499) == .amber)
        #expect(ContextLevel.of(0.85) == .red)
    }

    @Test func garbledLineIsSkippedAndTheRestParses() {
        let s = Self.parse(4..<8)
        #expect(s.contextTokens == 211_201)
        #expect(s.pending.isEmpty)
        #expect(Self.parse(4..<7).pending.map(\.id) == ["toolu_2"])
    }

    @Test func truncatedFirstLineFromTailIsSkipped() {
        let cut = String(Self.lines[1].dropFirst(60))
        let text = ([cut] + Self.lines[4..<5]).joined(separator: "\n")
        let s = TranscriptStatus.parse(Data(text.utf8))
        #expect(s.pending.map(\.id) == ["toolu_2"])
        #expect(s.contextTokens == 211_201)
    }

    @Test func summariesFollowToolRules() {
        let long = String(repeating: "x", count: 80)
        let cases: [(String, String, String)] = [
            ("Edit", #"{"file_path":"/a/b/c.swift"}"#, "Edit c.swift"),
            ("Write", #"{"file_path":"/a/new.txt"}"#, "Write new.txt"),
            ("Read", #"{}"#, "Read"),
            ("NotebookEdit", #"{"notebook_path":"/n/nb.ipynb"}"#, "NotebookEdit nb.ipynb"),
            ("Bash", #"{"command":"echo hi\nsecond"}"#, "Bash: echo hi"),
            ("Bash", #"{"command":"\#(long)"}"#, "Bash: " + String(long.prefix(60))),
            ("Task", #"{"description":"Find it"}"#, "Task: Find it"),
            ("Agent", #"{"description":"Dig"}"#, "Task: Dig"),
            ("mcp__linear__save_issue", #"{"x":1}"#, "linear: save_issue"),
            ("mcp__srv__a__b", #"{}"#, "srv: a__b"),
            ("Grep", #"{"pattern":"x"}"#, "Grep"),
        ]
        for (name, input, expected) in cases {
            let s = TranscriptStatus.parse(Data(Self.toolLine(id: "t", name: name, input: input).utf8))
            #expect(s.activity == expected)
        }
    }

    /// Counts closure calls from the model's detached tasks.
    final class Calls: @unchecked Sendable { // @unchecked: every access goes through the lock
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        var mtimes: [String: Date] = [:]
        var paths: [String: String] = [:]
        func hit(_ k: String) { lock.lock(); counts[k, default: 0] += 1; lock.unlock() }
        func count(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[k, default: 0] }
        func setMtime(_ id: String, _ d: Date?) { lock.lock(); mtimes[id] = d; lock.unlock() }
        func mtime(_ id: String) -> Date? { lock.lock(); defer { lock.unlock() }; return mtimes[id] }
    }

    @MainActor static func model(_ calls: Calls) -> TranscriptStatusModel {
        TranscriptStatusModel(
            path: { calls.hit("path:\($0)"); return "/t/\($0).jsonl" },
            mtime: { calls.hit("mtime:\($0)"); return calls.mtime($0) },
            read: { p in
                calls.hit("read")
                // A later mtime means the file grew: a second pending tool appears.
                let second = (calls.mtime(p)?.timeIntervalSince1970 ?? 0) >= 200
                    ? "\n" + Self.toolLine(id: "u", name: "Glob", input: "{}") : ""
                return Data((Self.toolLine(id: "t", name: "Grep", input: "{}") + second).utf8)
            }
        )
    }

    @MainActor @Test func unchangedMtimeDoesNotReread() async {
        let calls = Calls()
        calls.setMtime("/t/a.jsonl", Date(timeIntervalSince1970: 100))
        let m = Self.model(calls)
        await m.refresh(["a"])
        await m.refresh(["a"])
        #expect(calls.count("read") == 1)
        #expect(m.statuses["a"]?.activity == "Grep")
    }

    @MainActor @Test func changedMtimeReparses() async {
        let calls = Calls()
        calls.setMtime("/t/a.jsonl", Date(timeIntervalSince1970: 100))
        let m = Self.model(calls)
        await m.refresh(["a"])
        calls.setMtime("/t/a.jsonl", Date(timeIntervalSince1970: 200))
        await m.refresh(["a"])
        #expect(calls.count("read") == 2)
        #expect(m.statuses["a"]?.activity == "Glob")
    }

    @MainActor @Test func missingTranscriptIsLookedUpAgainOnlyAfterBackoff() async {
        let calls = Calls()
        let m = TranscriptStatusModel(path: { calls.hit("path:\($0)"); return nil }, mtime: { _ in nil }, read: { _ in nil })
        for _ in 0..<TranscriptStatusModel.missRetryTicks { await m.refresh(["a"]) }
        #expect(calls.count("path:a") == 1)
        await m.refresh(["a"])
        #expect(calls.count("path:a") == 2)
    }

    @MainActor @Test func paneWithoutProcessIsNeverRead() async {
        let calls = Calls()
        calls.setMtime("/t/a.jsonl", Date(timeIntervalSince1970: 100))
        let m = Self.model(calls)
        let idle = Pane(sessionId: "a", cwd: "/tmp", title: "t", origin: .new)
        #expect(!idle.hasProcess)
        m.start { [idle] in [idle] }
        try? await Task.sleep(for: .milliseconds(300))
        m.stop()
        #expect(calls.count("path:a") == 0 && calls.count("mtime:/t/a.jsonl") == 0 && calls.count("read") == 0)
        #expect(m.statuses.isEmpty)
    }

    @MainActor @Test func closedPaneStatusIsRemoved() async {
        let calls = Calls()
        calls.setMtime("/t/a.jsonl", Date(timeIntervalSince1970: 100))
        let m = Self.model(calls)
        await m.refresh(["a"])
        #expect(m.statuses["a"] != nil)
        await m.refresh([])
        #expect(m.statuses["a"] == nil)
        await m.refresh(["a"])
        #expect(calls.count("path:a") == 2 && calls.count("read") == 2)
    }

    @MainActor @Test func vanishedFileReresolvesPath() async {
        let calls = Calls()
        calls.setMtime("/t/a.jsonl", Date(timeIntervalSince1970: 100))
        let m = Self.model(calls)
        await m.refresh(["a"])
        calls.setMtime("/t/a.jsonl", nil)
        await m.refresh(["a"])
        calls.setMtime("/t/a.jsonl", Date(timeIntervalSince1970: 100))
        await m.refresh(["a"])
        #expect(calls.count("path:a") == 2)
        #expect(calls.count("read") == 2)
    }
}
