import Foundation
import SwiftUI

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

    /// The worktree folder `<repo>/.claude/worktrees/<name>` that holds `cwd`, or nil.
    static func root(of cwd: String) -> String? {
        guard let repo = parentRepo(of: cwd) else { return nil }
        let rest = cwd.dropFirst(repo.count + folder.count)
        return repo + folder + (rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "")
    }

    /// The branch `claude -w <name>` creates: `worktree-<name>` (T03), read from the folder name
    /// without running git. Only exact for names without `/`, which are the only ones the app makes.
    static func branch(of cwd: String) -> String? {
        root(of: cwd).map { "worktree-" + ($0 as NSString).lastPathComponent }
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

/// Cmd-Shift-N: names the worktree for a new session in the selected pane's repo.
struct WorktreeSheet: View {
    /// What the sheet was opened for: the selected session's folder and its git top level (resolved
    /// before the sheet opens, so a pane in a repo subfolder still names the repo).
    struct Request: Identifiable {
        let cwd: String
        let topLevel: String
        var id: String { cwd }

        /// The repo folder name, also for a session that already runs in a worktree.
        var project: String { ((Worktree.parentRepo(of: topLevel) ?? topLevel) as NSString).lastPathComponent }
    }

    let request: Request
    let create: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(request: Request, create: @escaping (String) -> Void) {
        self.request = request
        self.create = create
        _name = State(initialValue: Worktree.defaultName(project: request.project, date: Date()))
    }

    private var isValid: Bool { Worktree.isValidName(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Session in Worktree").font(.headline)
            Text("A new git worktree of \(request.project), in .claude/worktrees.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Worktree name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { submit() }
            Text("Letters, digits, dots, dashes and underscores; at most \(Worktree.maxNameLength); not starting with a dot or dash.")
                .font(.caption)
                .foregroundStyle(isValid ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
    }

    private func submit() {
        guard isValid else { return }
        create(name)
        dismiss()
    }
}
