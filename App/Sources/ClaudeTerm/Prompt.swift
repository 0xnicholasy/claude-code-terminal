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

    /// The one pending tool a button may answer: exactly one pending, and not an excluded tool.
    static func eligible(_ status: TranscriptStatus) -> TranscriptStatus.PendingTool? {
        guard status.pending.count == 1, let tool = status.pending.first,
              !excluded.contains(tool.name) else { return nil }
        return tool
    }

    /// True only while the session is still blocked on the tool the button was shown for, and the
    /// pane still has a process to receive the key.
    static func canSend(state: SessionState, shownToolUseId: String,
                        current: TranscriptStatus?, hasProcess: Bool) -> Bool {
        guard state == .blocked, hasProcess, let current,
              let tool = eligible(current) else { return false }
        return tool.id == shownToolUseId
    }
}
