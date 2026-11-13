import Foundation

/// Name and path rules for sessions started with `claude -w <name>` (T03, Claude Code 2.1.322):
/// the worktree goes to `<repo>/.claude/worktrees/<name>` on branch `worktree-<name>`, and the
/// session's cwd is the worktree root.
enum Worktree {
    static let maxNameLength = 64
    static let folder = "/.claude/worktrees/"

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Allowlist `[A-Za-z0-9._-]`, at most 64 characters, no leading `-` (claude reads `-w -x` as an
    /// option) or `.` (claude rejects `.` and `..`; a leading dot also hides the folder). No `/`:
    /// claude would turn it into `+`, so the folder would not match the name. All of these are inert
    /// in the `bash -c` string libghostty runs. The name also becomes branch `worktree-<name>`, so the
    /// parts git refuses in a ref (`..`, a trailing `.`, a trailing `.lock`) are rejected too.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxNameLength,
              let first = name.unicodeScalars.first, first != "-", first != ".",
              !name.contains(".."), !name.hasSuffix("."), !name.hasSuffix(".lock") else { return false }
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `<project>-yyMMdd-HHmm`, with every disallowed character of the project name turned into `-`,
    /// runs of `-` or `.` collapsed and leading `-`/`.` dropped. Falls back to `session` for an empty result.
    static func defaultName(project: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyMMdd-HHmm"
        let stamp = formatter.string(from: date)

        var base = ""
        for scalar in project.unicodeScalars {
            let c = allowed.contains(scalar) ? Character(scalar) : "-"
            if c == "-" || c == ".", base.last == c { continue }
            base.append(c)
        }
        while let f = base.first, f == "-" || f == "." { base.removeFirst() }
        base = String(base.prefix(maxNameLength - stamp.count - 1))
        while let l = base.last, l == "-" || l == "." { base.removeLast() }
        if base.isEmpty { base = "session" }
        return base + "-" + stamp
    }

    static func path(repo: String, name: String) -> String {
        (repo.hasSuffix("/") ? String(repo.dropLast()) : repo) + folder + name
    }

    /// The repo a worktree session's cwd belongs to: `<repo>` for `<repo>/.claude/worktrees/<name>`
    /// (or a folder inside it); nil for any other path. The folder name is not held to `isValidName`:
    /// claude itself names folders outside that set (`-w a/b` makes `a+b`).
    static func parentRepo(of cwd: String) -> String? {
        guard let range = cwd.range(of: folder, options: .backwards) else { return nil }
        let repo = String(cwd[..<range.lowerBound])
        let name = cwd[range.upperBound...].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard repo.hasPrefix("/"), !name.isEmpty, name != ".", name != ".." else { return nil }
        return repo
    }
}
