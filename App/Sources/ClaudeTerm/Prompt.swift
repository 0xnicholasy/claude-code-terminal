import CCProtocol
import Foundation
import GhosttyTerminal

/// Answering a pending tool-permission prompt from the sidebar (decisions D7 and D10). Pure logic:
/// the key sending and the fresh transcript read are injected closures on `WorkspaceModel`.
enum PromptAnswer {
    /// Tools whose prompt is not a plain yes/no, so a bare `1` or Esc would answer it wrongly.
    private static let excluded: Set<String> = ["AskUserQuestion", "ExitPlanMode", "Task", "Agent"]

    /// Shown when the guard refuses: the prompt was answered or replaced since the button was drawn.
    static let staleNotice = "That prompt is no longer waiting; nothing was sent."
    /// Shown when the pane has no terminal to receive the key.
    static let failedSendNotice = "Could not send the answer to the terminal."

    /// `1` approves once and Esc denies (confirmed live on Claude Code 2.1.322).
    static func keys(allow: Bool) -> TerminalKey {
        allow ? .digit1 : .escape
    }

    private static let fileTools: Set<String> = ["Edit", "Write", "Read", "NotebookEdit"]
    /// Longest Bash command shown whole on the row and the notification (decision D15).
    static let maxCommandLength = 60

    /// What the row and the notification show for the tool, or nil when that text would not be the
    /// whole action (decision D15): a single-line Bash command of at most 60 characters, or a file
    /// tool whose path lies strictly inside `cwd`, shown relative to it. Symlinks are resolved on both
    /// sides, so `/tmp/x` and `/private/tmp/x` match and `cwd/../other` does not.
    static func label(_ tool: TranscriptStatus.PendingTool, cwd: String) -> String? {
        guard let detail = tool.detail else { return nil }
        if tool.name == "Bash" {
            let command = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, command.unicodeScalars.count <= maxCommandLength,
                  isPlainText(command) else { return nil }
            return "Bash: " + command
        }
        guard fileTools.contains(tool.name), !cwd.isEmpty, let relative = relativePath(detail, in: cwd) else { return nil }
        return tool.name + " " + relative
    }

    /// Printable ASCII only (0x20 to 0x7E): no control, escape, bidi, zero-width or combining
    /// characters that could make the shown text differ from what runs.
    private static func isPlainText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    /// `path` relative to `cwd` when it lies strictly inside it, else nil. Refused when either path
    /// has a `..` component, when `cwd` is not absolute, and when the project root is `/` or the home
    /// folder (too broad to mean "this project").
    private static func relativePath(_ path: String, in cwd: String) -> String? {
        guard path.hasPrefix("/"), cwd.hasPrefix("/"),
              !path.split(separator: "/").contains(".."), !cwd.split(separator: "/").contains(".."),
              let root = resolved(cwd), let file = resolved(path),
              root != "/", root != resolved(NSHomeDirectory()) else { return nil }
        let prefix = root + "/"
        guard file.hasPrefix(prefix), file.count > prefix.count else { return nil }
        let relative = String(file.dropFirst(prefix.count))
        return isPlainText(relative) ? relative : nil
    }

    /// Standardized path with symlinks resolved. The file itself may not exist yet (a Write), so the
    /// nearest existing ancestor is resolved with `realpath` and the rest is appended; the Foundation
    /// resolver treats a missing leaf differently and would not map `/tmp` and `/private/tmp` alike.
    /// A dangling symlink counts as existing (`attributesOfItem` does not follow links) and makes
    /// `realpath` fail, so the path is refused rather than judged by its link name.
    private static func resolved(_ path: String) -> String? {
        var existing = URL(fileURLWithPath: path).standardizedFileURL.path
        var rest: [String] = []
        while existing != "/", (try? FileManager.default.attributesOfItem(atPath: existing)) == nil {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let real = realpath(existing, nil) else { return nil }
        defer { free(real) }
        return ([String(cString: real)] + rest).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }

    /// The one pending tool a button may answer: exactly one pending, not an excluded tool, and
    /// shown in full (`label`).
    static func eligible(_ status: TranscriptStatus, cwd: String) -> TranscriptStatus.PendingTool? {
        guard status.pending.count == 1, let tool = status.pending.first,
              !excluded.contains(tool.name), label(tool, cwd: cwd) != nil else { return nil }
        return tool
    }

    /// True only while the session is still blocked on the tool the button was shown for, and the
    /// pane still has a process to receive the key.
    static func canSend(state: SessionState, shownToolUseId: String,
                        current: TranscriptStatus?, hasProcess: Bool, cwd: String) -> Bool {
        guard state == .blocked, hasProcess, let current,
              let tool = eligible(current, cwd: cwd) else { return false }
        return tool.id == shownToolUseId
    }
}
