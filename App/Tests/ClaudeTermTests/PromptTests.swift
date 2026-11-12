import CCProtocol
import Foundation
import GhosttyTerminal
import Testing
@testable import ClaudeTerm

struct PromptTests {
    static func status(_ tools: [(String, String)]) -> TranscriptStatus {
        TranscriptStatus(pending: tools.map { .init(id: $0.0, name: $0.1, summary: $0.1) })
    }

    @Test func allowPressesOneAndDenyPressesEscape() {
        #expect(PromptAnswer.keys(allow: true) == .digit1)
        #expect(PromptAnswer.keys(allow: false) == .escape)
    }

    @Test func singlePlainToolIsEligible() {
        #expect(PromptAnswer.eligible(Self.status([("t1", "Bash")]))?.id == "t1")
    }

    @Test func twoPendingToolsAreNotEligible() {
        #expect(PromptAnswer.eligible(Self.status([("t1", "Bash"), ("t2", "Edit")])) == nil)
        #expect(PromptAnswer.eligible(Self.status([])) == nil)
    }

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode", "Task", "Agent"])
    func excludedToolIsNotEligible(name: String) {
        #expect(PromptAnswer.eligible(Self.status([("t1", name)])) == nil)
    }

    @Test func canSendOnlyForTheShownToolWhileBlockedWithAProcess() {
        let s = Self.status([("t1", "Bash")])
        #expect(PromptAnswer.canSend(state: .blocked, shownToolUseId: "t1", current: s, hasProcess: true))
        #expect(!PromptAnswer.canSend(state: .running, shownToolUseId: "t1", current: s, hasProcess: true))
        #expect(!PromptAnswer.canSend(state: .blocked, shownToolUseId: "t0", current: s, hasProcess: true))
        #expect(!PromptAnswer.canSend(state: .blocked, shownToolUseId: "t1", current: s, hasProcess: false))
        #expect(!PromptAnswer.canSend(state: .blocked, shownToolUseId: "t1", current: nil, hasProcess: true))
    }
}
