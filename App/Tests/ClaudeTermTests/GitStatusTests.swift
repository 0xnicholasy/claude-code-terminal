import Foundation
import Testing
@testable import ClaudeTerm

struct GitStatusTests {
    @Test func porcelainV2CountsStagedModifiedUntrackedConflictsAndAheadBehind() throws {
        let out = """
        # branch.oid 1f951f6e0c0ffee
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 M. N... 100644 100644 100644 aaa bbb staged.swift
        1 .M N... 100644 100644 100644 aaa bbb edited.swift
        1 MM N... 100644 100644 100644 aaa bbb both.swift
        2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 aaa bbb ccc clash.swift
        ? notes.txt
        ? scratch.txt

        """
        let s = try #require(GitStatus.parse(out))
        #expect(s.branch == "main" && s.ahead == 2 && s.behind == 1)
        #expect(s.staged == 3 && s.modified == 2 && s.untracked == 2 && s.conflicted == 1)
        #expect(!s.isClean)
    }

    @Test func detachedHeadShowsShortHashAndCleanTreeIsClean() throws {
        let s = try #require(GitStatus.parse("# branch.oid 1f951f6e0c0ffee\n# branch.head (detached)\n"))
        #expect(s.branch == "1f951f6" && s.isClean && s.ahead == 0)
        #expect(GitStatus.parse("") == nil) // not a repository: git prints nothing on stdout
    }
}
