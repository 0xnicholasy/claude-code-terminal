import AppKit
import CCProtocol
import SwiftUI

@main
struct ClaudeTermApp: App {
    @StateObject private var model = Bootstrap.makeModel()

    var body: some Scene {
        Window("ClaudeTerm", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 480)
                .task { Bootstrap.start(model) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session...") {
                    if let cwd = DirectoryPicker.choose() { model.newSession(cwd: cwd) }
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Close Pane") {
                    if let id = model.selectedID { model.close(id) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.selectedID == nil)
            }
        }
    }
}

@MainActor
enum TakeoverAlert {
    static func confirm(_ s: SessionInfo) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move \(SessionGrouping.displayName(s)) here?"
        var info = "ClaudeTerm stops claude in the other terminal (pid \(s.pid.map(String.init) ?? "?")) "
            + "and resumes the conversation in a pane here. The other tab returns to its shell prompt."
        if s.state == .running {
            info += "\n\nThis session is working right now. Stopping it interrupts the current reply."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Take Over")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
enum Bootstrap {
    /// The unit-test host launches this app; it must not read the user's layout or run `claude`.
    static var isUnderTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }

    static let claude = ClaudeBinary()

    static func makeModel() -> WorkspaceModel {
        if isUnderTest { return WorkspaceModel(store: nil, claudePath: { nil }) }
        InheritedSessionEnv.scrubProcessEnvironment()
        let binary = claude
        let model = WorkspaceModel(store: LayoutStore(url: LayoutStore.defaultURL()), claudePath: { binary.get() },
                                   notify: { DaemonNotifier.send($0, sessionId: $1) },
                                   request: { await DaemonClient.request($0, sessionId: $1) },
                                   confirm: TakeoverAlert.confirm)
        // Restore before any window exists: window frame callbacks persist the layout, and a
        // persist that ran first would overwrite the saved file with an empty one.
        model.restore()
        return model
    }

    static func start(_ model: WorkspaceModel) {
        guard !isUnderTest else { return }
        // ccgovd socket when the daemon is up; `claude agents --json` polling otherwise.
        model.consume(PreferDaemonSource.live(claude: claude) { mode in
            NSLog("ClaudeTerm session source: %@", mode == .daemon ? "ccgovd socket" : "claude agents polling")
            Task { @MainActor in
                model.daemonConnected = mode == .daemon
                if mode == .daemon { model.resyncDaemon() }
            }
        })
    }
}
