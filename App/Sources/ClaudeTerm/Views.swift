import AppKit
import CCProtocol
import GhosttyTerminal
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            PaneArea(model: model)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    if let cwd = DirectoryPicker.choose() { model.newSession(cwd: cwd) }
                } label: {
                    Label("New Session", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button {
                    if let id = model.selectedID { model.close(id) }
                } label: {
                    Label("Close Pane", systemImage: "xmark")
                }
                .disabled(model.selectedID == nil)
            }
        }
        .background(WindowFrameReader(initial: model.windowFrameForRestore) { model.windowFrame = $0 })
        .alert("ClaudeTerm", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        let rows = model.rows
        List(selection: Binding<String?>(
            get: { model.selectedID },
            set: { id in
                if let id, let session = rows.first(where: { $0.sessionId == id }) { model.open(session) }
            }
        )) {
            ForEach(SessionGrouping.group(rows)) { group in
                Section {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session).tag(session.sessionId)
                    }
                } header: {
                    Text(group.name).help(group.path)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if rows.isEmpty { Text("No sessions").foregroundStyle(.secondary) }
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .help(label)
            Text(SessionGrouping.displayName(session)).lineLimit(1)
            Spacer(minLength: 4)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(megabytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private var megabytes: String {
        session.state == .hibernated || session.rssBytes == 0 ? "-" : "\(session.rssBytes / 1_048_576) MB"
    }

    private var label: String {
        switch session.state {
        case .running: "running"
        case .idle: "idle"
        case .blocked: "blocked"
        case .hibernated: "hibernated"
        case .unknown: "unknown"
        }
    }

    private var symbol: String {
        switch session.state {
        case .running: "circle.fill"
        case .idle: "circle"
        case .blocked: "exclamationmark.circle.fill"
        case .hibernated: "moon.zzz"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch session.state {
        case .running: .green
        case .blocked: .orange
        default: .secondary
        }
    }
}

struct PaneArea: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ZStack {
            ForEach(model.panes.filter(\.hasProcess)) { pane in
                PaneView(pane: pane, isSelected: pane.id == model.selectedID)
            }
            if model.selectedID == nil {
                Text("Choose a session or create a new one").foregroundStyle(.secondary)
            }
        }
    }
}

struct PaneView: View {
    let pane: Pane
    let isSelected: Bool

    var body: some View {
        if let state = pane.viewState() {
            TerminalSurfaceView(context: state)
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .onAppear { apply(state) }
                .onChange(of: isSelected) { _, _ in apply(state) }
        }
    }

    /// Hidden panes stop rendering (releases GPU memory); the visible one takes keyboard focus.
    private func apply(_ state: TerminalViewState) {
        state.isSurfaceVisible = isSelected
        if isSelected { state.requestFocus() }
    }
}

/// Reports the hosting window's frame on move/resize and applies a saved frame once.
struct WindowFrameReader: NSViewRepresentable {
    var initial: LayoutFrame?
    var onChange: @MainActor (LayoutFrame) -> Void

    func makeNSView(context _: Context) -> TrackerView {
        let v = TrackerView()
        v.initial = initial
        v.onChange = onChange
        return v
    }

    func updateNSView(_ view: TrackerView, context _: Context) { view.onChange = onChange }

    final class TrackerView: NSView {
        var initial: LayoutFrame?
        var onChange: (@MainActor (LayoutFrame) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if let f = initial {
                window.setFrame(NSRect(x: f.x, y: f.y, width: f.width, height: f.height), display: true)
                initial = nil
            }
            let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let w = self?.window else { return }
                        let r = w.frame
                        self?.onChange?(LayoutFrame(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height))
                    }
                }
            }
        }

        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
