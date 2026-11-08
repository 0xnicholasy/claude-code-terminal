import Foundation
import SwiftUI

/// Git state of one working tree, from `git status --porcelain=v2 --branch`.
struct GitStatus: Equatable {
    /// Branch name, or a short commit hash when HEAD is detached.
    var branch: String
    var ahead = 0
    var behind = 0
    var staged = 0
    var modified = 0
    var untracked = 0
    var conflicted = 0

    /// This runs unprompted in whatever folder a session uses, which may be a downloaded repo with a
    /// hostile .git/config. Turn off the config keys that make `git status` run a command.
    /// Residual: a clean filter set in that same .git/config can still run; git has no switch for it.
    static let safeConfig = ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                             "-c", "core.hooksPath=/dev/null"]

    var isClean: Bool { staged == 0 && modified == 0 && untracked == 0 && conflicted == 0 }

    static func parse(_ text: String) -> GitStatus? {
        var status: GitStatus?
        var oid = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: " ", omittingEmptySubsequences: false)
            switch f.first {
            case "#" where f.count >= 3:
                switch f[1] {
                case "branch.oid": oid = String(f[2])
                case "branch.head": status = GitStatus(branch: String(f[2...].joined(separator: " ")))
                case "branch.ab" where f.count >= 4:
                    status?.ahead = Int(f[2].dropFirst()) ?? 0
                    status?.behind = Int(f[3].dropFirst()) ?? 0
                default: break
                }
            case "1", "2":
                // "1 XY ...": X is the index (staged) state, Y the work tree state; "." means unchanged.
                guard f.count > 1, f[1].count == 2 else { continue }
                if f[1].first != "." { status?.staged += 1 }
                if f[1].last != "." { status?.modified += 1 }
            case "u": status?.conflicted += 1
            case "?": status?.untracked += 1
            default: break
            }
        }
        if status?.branch == "(detached)" { status?.branch = String(oid.prefix(7)) }
        return status
    }
}

@MainActor
final class GitStatusModel: ObservableObject {
    @Published private(set) var status: GitStatus?
    private var cwd: String?
    private var task: Task<Void, Never>?

    /// Follows one folder, refreshing every 5 seconds; nil stops.
    func track(_ cwd: String?) {
        guard cwd != self.cwd else { return }
        self.cwd = cwd
        task?.cancel()
        status = nil
        guard let cwd, !cwd.isEmpty else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let data = await ProcessRunner.run("/usr/bin/git", ["-C", cwd] + GitStatus.safeConfig
                    + ["--no-optional-locks", "status", "--porcelain=v2", "--branch"], timeout: 10)
                guard !Task.isCancelled, let self, self.cwd == cwd else { return }
                self.status = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(GitStatus.parse)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// Toolbar item: branch, changed file counts, commits ahead and behind upstream.
struct GitChip: View {
    let status: GitStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).imageScale(.small)
            Text(Self.short(status.branch)).fontWeight(.medium)
            if status.conflicted > 0 { Text("!\(status.conflicted)").foregroundStyle(.red) }
            if status.staged > 0 { Text("+\(status.staged)").foregroundStyle(.green) }
            if status.modified > 0 { Text("~\(status.modified)").foregroundStyle(Palette.accent) }
            if status.untracked > 0 { Text("?\(status.untracked)").foregroundStyle(.secondary) }
            if status.ahead > 0 { Text("\(Image(systemName: "arrow.up"))\(status.ahead)").foregroundStyle(.secondary) }
            if status.behind > 0 { Text("\(Image(systemName: "arrow.down"))\(status.behind)").foregroundStyle(.secondary) }
        }
        .font(.callout.monospacedDigit())
        .help(help)
    }

    /// Long branch names keep their start and end ("feat/very-lo...-thing") instead of stretching the toolbar.
    static func short(_ branch: String, max: Int = 22) -> String {
        guard branch.count > max else { return branch }
        return branch.prefix(max / 2 - 1) + "\u{2026}" + branch.suffix(max / 2)
    }

    private var help: String {
        var lines = ["Branch \(status.branch)"]
        if status.isClean { lines.append("Working tree clean") }
        if status.conflicted > 0 { lines.append("\(status.conflicted) conflicted") }
        if status.staged > 0 { lines.append("\(status.staged) staged") }
        if status.modified > 0 { lines.append("\(status.modified) modified") }
        if status.untracked > 0 { lines.append("\(status.untracked) untracked") }
        if status.ahead > 0 || status.behind > 0 { lines.append("\(status.ahead) ahead, \(status.behind) behind upstream") }
        return lines.joined(separator: "\n")
    }
}
