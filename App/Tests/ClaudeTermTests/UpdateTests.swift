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

    @Test func signingSkipsExpiredIdentities() {
        let out = """
        Policy: Code Signing
          Matching identities
          1) 45D0312F6922EEE9D57A6D05AB1416508C3CFA23 "Apple Development: a@b.c (G9PV52876B)" (CSSMERR_TP_CERT_EXPIRED)
          2) DC4CE8543B3F051600333E2B927009D68F1E99DA "Apple Development: a@b.c (G9PV52876B)"
             2 identities found
        """
        #expect(CodeSigning.identity(in: out) == "DC4CE8543B3F051600333E2B927009D68F1E99DA")
        #expect(CodeSigning.identity(in: "     0 identities found") == nil)
    }
}
