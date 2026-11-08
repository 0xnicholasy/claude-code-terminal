import Foundation
import Testing
@testable import ClaudeTerm

struct UpdateTests {
    @Test func formulaTagGivesTheReleasedVersion() {
        let formula = """
          url "ssh://git@github.com/0xnicholasy/claude-code-terminal.git",
              using:    :git,
              tag:      "v0.1.10",
              revision: "9829b1e41b53145c42312b203e3b75b7fb1739be"
        """
        #expect(Version.fromFormula(formula) == "0.1.10")
        #expect(Version.fromFormula("class Claudeterm < Formula\nend") == nil)
    }

    @Test func versionsCompareNumericallyNotAsText() {
        #expect(Version.isNewer("0.1.10", than: "0.1.9"))
        #expect(!Version.isNewer("0.1.9", than: "0.1.10"))
        #expect(!Version.isNewer("1.0", than: "1.0.0"))
        #expect(Version.isNewer("1.0.1", than: "1.0"))
    }
}
