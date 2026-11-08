import Foundation
import Testing
@testable import ClaudeTerm

struct MarkdownTests {
    @Test func blocksCoverHeadingsListsCodeQuotesTablesAndParagraphs() {
        let md = """
        ## Result
        Tests **pass**
        on main.

        - one
          - nested
        2. two
        ```swift
        let x = 1

        print(x)
        ```
        > note
        | a | b |
        |---|:-:|
        | 1 | 2 |
        ---
        """
        #expect(MarkdownBlock.parse(md) == [
            .heading(level: 2, text: "Result"),
            .paragraph("Tests **pass**\non main."),
            .listItem(indent: 0, marker: "\u{2022}", text: "one"),
            .listItem(indent: 1, marker: "\u{2022}", text: "nested"),
            .listItem(indent: 0, marker: "2.", text: "two"),
            .code(language: "swift", text: "let x = 1\n\nprint(x)"),
            .quote("note"),
            .table([["a", "b"], ["1", "2"]]),
            .rule,
        ])
        #expect(MarkdownBlock.parse("#hashtag") == [.paragraph("#hashtag")])
    }

    @Test func conversationKeepsPromptsAndJoinsReplyTextSkippingToolsSidechainsAndCommands() {
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"first question"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-11-08T01:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#,
            #"{"type":"assistant","uuid":"s1","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent"}]}}"#,
            #"{"type":"user","uuid":"c1","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#,
            #"{"type":"user","uuid":"m1","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
            #"{"type":"user","uuid":"u3","message":{"role":"user","content":[{"type":"text","text":"second"}]}}"#,
            ###"{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"text","text":"## Two"}]}}"###,
            "not json",
        ]
        let data = Data(lines.joined(separator: "\n").utf8)
        let entries = TranscriptReplies.parse(data)
        #expect(entries.map(\.text) == ["first question", "Looking.\n\nDone.", "second", "## Two"])
        #expect(entries.map(\.isPrompt) == [true, false, true, false])
        #expect(entries[1].id == "a1" && entries[1].date != nil)
        #expect(TranscriptReplies.parse(data, limit: 1).map(\.id) == ["a3"])
    }

    @Test func tailStartsAtALineBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("aaaa\nbbbb\ncccc\n".utf8).write(to: url)
        let data = try #require(TranscriptReplies.tail(url.path, maxBytes: 7))
        #expect(String(decoding: data, as: UTF8.self) == "cccc\n")
    }
}
