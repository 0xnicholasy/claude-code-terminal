import Foundation
import Testing
@testable import ClaudeTerm

struct ClipboardTests {
    @Test func repeatCopyMovesToTopAndHistoryIsCapped() {
        var h = ClipboardHistory(limit: 3)
        for t in ["a", "b", "c", "a", "  \n", "d"] { h.add(t) }
        #expect(h.items.map(\.text) == ["d", "a", "c"]) // "a" moved up, blank skipped, "b" dropped by the cap
        #expect(h.matching("A").map(\.text) == ["a"])
        #expect(h.matching(" ").count == 3)
    }

    @Test func passwordManagerCopiesAreNotRecorded() {
        #expect(ClipboardHistory.shouldRecord(types: ["public.utf8-plain-text"]))
        #expect(!ClipboardHistory.shouldRecord(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!ClipboardHistory.shouldRecord(types: ["public.png"]))
    }
}
