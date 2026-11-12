import AppKit
import CCProtocol
import SwiftUI

@main
struct ClaudeTermApp: App {
    @StateObject private var model = Bootstrap.makeModel()
    @StateObject private var usage = Bootstrap.makeUsage()
    @StateObject private var transcripts = Bootstrap.makeTranscripts()
    @StateObject private var clipboard = ClipboardModel()
    @StateObject private var updates = UpdateModel()
    @AppStorage(RepliesModel.enabledKey) private var showReplies = true

    var body: some Scene {
        Window("ClaudeTerm", id: "main") {
            ContentView(model: model, usage: usage, clipboard: clipboard, transcripts: transcripts)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    Bootstrap.start(model)
                    guard !Bootstrap.isUnderTest else { return }
                    clipboard.start()
                    transcripts.start { [model] in model.panes }
                    updates.startAutomatic { v in
                        model.notice = "ClaudeTerm \(v) is available. ClaudeTerm > About ClaudeTerm to install it."
                    }
                }
        }
        Window("About ClaudeTerm", id: "about") {
            AboutView(updates: updates)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            AppInfoCommands(updates: updates)
            CommandGroup(replacing: .newItem) {
                Button("New Session...") {
                    if let cwd = DirectoryPicker.choose() { model.newSession(cwd: cwd) }
                }
                .keyboardShortcut("n")
                Button("New Session in This Project") { model.newSessionInCurrentProject() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.selectedID == nil)
            }
            CommandGroup(after: .newItem) {
                Button("Close Pane") {
                    if let id = model.selectedID { model.close(id) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.selectedID == nil)
            }
            CommandGroup(after: .pasteboard) {
                Button("Clipboard History") { clipboard.isShown.toggle() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Toggle("Formatted Output", isOn: $showReplies)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            NavigationCommands(model: model)
        }
    }
}

/// App menu: About opens the app's own window (version, author, updates) instead of the stock panel.
struct AppInfoCommands: Commands {
    @ObservedObject var updates: UpdateModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ClaudeTerm") { openWindow(id: "about") }
            Button("Check for Updates...") {
                openWindow(id: "about")
                Task { await updates.check() }
            }
        }
    }
}

/// Go menu: every way to move between panes, sessions and tabs from the keyboard.
struct NavigationCommands: Commands {
    @ObservedObject var model: WorkspaceModel

    var body: some Commands {
        CommandMenu("Go") {
            Button("Sessions") { model.tab = .sessions }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Usage") { model.tab = .usage }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Button("Toggle Sessions / Usage") { model.tab = model.tab == .usage ? .sessions : .usage }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Divider()
            Button("Next Pane") { model.cyclePane(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Pane") { model.cyclePane(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Pane (Ctrl-Tab)") { model.cyclePane(by: 1) }
                .keyboardShortcut(.tab, modifiers: [.control])
            Button("Previous Pane (Ctrl-Shift-Tab)") { model.cyclePane(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            Button("Next Session in Sidebar") { model.cycleSession(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Session in Sidebar") { model.cycleSession(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button(n == 9 ? "Last Pane" : "Pane \(n)") { model.selectPane(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .disabled(n != 9 && n > model.panes.count || model.panes.isEmpty)
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

    static func makeUsage() -> UsageModel {
        if isUnderTest { return UsageModel() }
        let binary = claude
        return UsageModel(claudePath: { binary.get() }, defaults: .standard)
    }

    static func makeTranscripts() -> TranscriptStatusModel { TranscriptStatusModel() }

    static func makeModel() -> WorkspaceModel {
        if isUnderTest { return WorkspaceModel(store: nil, claudePath: { nil }) }
        InheritedSessionEnv.scrubProcessEnvironment()
        LoginPath.adopt()
        let binary = claude
        let model = WorkspaceModel(store: LayoutStore(url: LayoutStore.defaultURL()), claudePath: { binary.get() },
                                   notify: { DaemonNotifier.send($0, sessionId: $1) },
                                   request: { await DaemonClient.request($0, sessionId: $1) },
                                   confirm: TakeoverAlert.confirm,
                                   paneProcess: { PaneProcess.claudePid(sessionId: $0) },
                                   attention: { AttentionNotifier.shared.handle($0, waitingCount: $1) })
        AttentionNotifier.shared.isShowing = { [weak model] id in
            NSApp.isActive && model?.tab == .sessions && model?.selectedID == id
        }
        AttentionNotifier.shared.onOpen = { [weak model] id in
            guard let model, let session = model.rows.first(where: { $0.sessionId == id }) else { return }
            model.tab = .sessions
            model.open(session)
        }
        // Restore before any window exists: window frame callbacks persist the layout, and a
        // persist that ran first would overwrite the saved file with an empty one.
        model.restore()
        return model
    }

    static func start(_ model: WorkspaceModel) {
        guard !isUnderTest else { return }
        AttentionNotifier.shared.start()
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
