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
        }
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
        let binary = claude
        let model = WorkspaceModel(store: LayoutStore(url: LayoutStore.defaultURL()), claudePath: { binary.get() })
        // Restore before any window exists: window frame callbacks persist the layout, and a
        // persist that ran first would overwrite the saved file with an empty one.
        model.restore()
        return model
    }

    static func start(_ model: WorkspaceModel) {
        guard !isUnderTest else { return }
        model.consume(AgentsPollingSource(claude: claude))
    }
}
