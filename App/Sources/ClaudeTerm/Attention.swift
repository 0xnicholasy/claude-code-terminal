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

/// macOS notifications for sessions waiting on the user, and the Dock badge with their count.
/// Clicking a notification brings the app forward and opens that session.
@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotifier()
    private static let prefix = "waiting-"

    /// Opens a session by id (set by the app to `WorkspaceModel.open`).
    var onOpen: ((String) -> Void)?
    /// True for the session the user is looking at right now: no banner for it, it still counts for the badge.
    var isShowing: ((String) -> Bool)?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func handle(_ change: WaitingChange, waitingCount: Int) {
        let center = UNUserNotificationCenter.current()
        if !change.stopped.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: change.stopped.map { Self.prefix + $0 })
        }
        let fresh = change.started.filter { !(isShowing?($0.sessionId) ?? false) }
        for s in fresh {
            let content = UNMutableNotificationContent()
            content.title = SessionGrouping.displayName(s)
            content.subtitle = SidebarLayout.projectName(s.cwd)
            content.body = "Waiting for your answer"
            content.sound = .default
            content.threadIdentifier = s.cwd
            content.userInfo = ["sessionId": s.sessionId]
            center.add(UNNotificationRequest(identifier: Self.prefix + s.sessionId, content: content, trigger: nil))
        }
        if !fresh.isEmpty, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        NSApp.dockTile.badgeLabel = waitingCount > 0 ? "\(waitingCount)" : nil
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["sessionId"] as? String else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            onOpen?(id)
        }
    }

    /// Show the banner even while the app is in front: the waiting session is usually another pane.
    nonisolated func userNotificationCenter(_: UNUserNotificationCenter,
                                            willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
