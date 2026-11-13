import AppKit
import CCProtocol
import Foundation
import UserNotifications

/// Sessions that started or stopped waiting for the user since the previous update.
struct WaitingChange: Equatable {
    var started: [SessionInfo] = []
    var stopped: [String] = []
}

/// Finds sessions that just started waiting for an answer (a permission prompt or a question).
/// The first update only records what is already waiting, so launching the app does not replay old
/// prompts. A session that drops out of the list for a moment keeps its waiting mark, so the same
/// prompt is not announced twice; only a concrete state (working, idle, hibernated) clears it.
struct WaitingTracker: Equatable {
    private var waiting: Set<String> = []
    private var primed = false

    mutating func update(_ rows: [SessionInfo]) -> WaitingChange {
        var change = WaitingChange()
        for s in rows {
            switch s.state {
            case .blocked:
                if waiting.insert(s.sessionId).inserted, primed { change.started.append(s) }
            case .running, .idle, .hibernated:
                if waiting.remove(s.sessionId) != nil { change.stopped.append(s.sessionId) }
            case .unknown:
                break
            }
        }
        primed = true
        return change
    }
}

/// What a waiting notification shows, and whether it carries Allow / Deny buttons.
struct PromptContent: Equatable {
    var category: String?
    var body: String
    var toolUseId: String?
}

/// The notification buttons are offered only for a launched pane blocked on exactly one answerable tool.
enum PromptNotification {
    static let category = "waiting-prompt"
    static let allow = "allow"
    static let deny = "deny"
    static let plainBody = "Waiting for your answer"

    static func content(launched: Bool, status: TranscriptStatus?, cwd: String) -> PromptContent {
        guard launched, let status, let tool = PromptAnswer.eligible(status, cwd: cwd),
              let label = PromptAnswer.label(tool, cwd: cwd) else {
            return PromptContent(category: nil, body: plainBody, toolUseId: nil)
        }
        return PromptContent(category: category, body: label, toolUseId: tool.id)
    }

    /// A fresh tail-parse of one transcript. Not the 2 s status cache: that can lag the blocked state.
    static func freshStatus(sessionId: String) -> TranscriptStatus? {
        guard let path = TranscriptReplies.transcriptPath(sessionId: sessionId),
              let data = TranscriptReplies.tail(path, maxBytes: 256 * 1024) else { return nil }
        return TranscriptStatus.parse(data)
    }
}

/// macOS notifications for sessions waiting on the user, and the Dock badge with their count.
/// Clicking a notification brings the app forward and opens that session; the Allow / Deny buttons
/// answer the prompt without bringing the app forward.
@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotifier()
    private static let prefix = "waiting-"

    /// Opens a session by id (set by the app to `WorkspaceModel.open`).
    var onOpen: ((String) -> Void)?
    /// True for the session the user is looking at right now: no banner for it, it still counts for the badge.
    var isShowing: ((String) -> Bool)?
    /// Answers a prompt: session id, tool use id, allow (set by the app to `WorkspaceModel.answer`).
    var onAnswer: ((String, String, Bool) -> Void)?
    /// True when the session has a pane with a running process.
    var paneLaunched: ((String) -> Bool)?
    /// A fresh read of the session's pending tools.
    var pendingStatus: (@Sendable (String) -> TranscriptStatus?)?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let allow = UNNotificationAction(identifier: PromptNotification.allow, title: "Allow",
                                         options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: PromptNotification.deny, title: "Deny", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(
            identifier: PromptNotification.category, actions: [allow, deny],
            intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: PromptNotification.plainBody,
            options: [])])
    }

    func handle(_ change: WaitingChange, waitingCount: Int) {
        let center = UNUserNotificationCenter.current()
        if !change.stopped.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: change.stopped.map { Self.prefix + $0 })
        }
        let fresh = change.started.filter { !(isShowing?($0.sessionId) ?? false) }
        for s in fresh {
            guard paneLaunched?(s.sessionId) ?? false, let read = pendingStatus else {
                post(s, PromptNotification.content(launched: false, status: nil, cwd: s.cwd), to: center)
                continue
            }
            // The fresh read scans ~/.claude/projects and parses a 256 KB tail: keep it off the main actor.
            let id = s.sessionId
            Task {
                let status = await Task.detached { read(id) }.value
                post(s, PromptNotification.content(launched: true, status: status, cwd: s.cwd), to: center)
            }
        }
        if !fresh.isEmpty, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        NSApp.dockTile.badgeLabel = waitingCount > 0 ? "\(waitingCount)" : nil
    }

    private func post(_ s: SessionInfo, _ prompt: PromptContent, to center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = SessionGrouping.displayName(s)
        content.subtitle = SidebarLayout.projectName(s.cwd)
        content.body = prompt.body
        content.sound = .default
        content.threadIdentifier = s.cwd
        content.userInfo = ["sessionId": s.sessionId]
        if let category = prompt.category, let toolUseId = prompt.toolUseId {
            content.categoryIdentifier = category
            content.userInfo["toolUseId"] = toolUseId
        }
        center.add(UNNotificationRequest(identifier: Self.prefix + s.sessionId, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["sessionId"] as? String else { return }
        switch response.actionIdentifier {
        case PromptNotification.allow, PromptNotification.deny:
            guard let toolUseId = info["toolUseId"] as? String else { return }
            let allow = response.actionIdentifier == PromptNotification.allow
            await MainActor.run { onAnswer?(id, toolUseId, allow) }
        case UNNotificationDefaultActionIdentifier:
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                onOpen?(id)
            }
        default:
            break
        }
    }

    /// Show the banner even while the app is in front: the waiting session is usually another pane.
    nonisolated func userNotificationCenter(_: UNUserNotificationCenter,
                                            willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
