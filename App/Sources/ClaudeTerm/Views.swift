import AppKit
import CCProtocol
import GhosttyTerminal
import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case usage = "Usage"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var model: WorkspaceModel
    @StateObject private var usage = UsageModel()
    @State private var tab: DetailTab = .sessions

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        } detail: {
            ZStack {
                // Panes stay mounted under the Usage tab so their terminals keep running untouched.
                VStack(spacing: 0) {
                    PaneArea(model: model)
                    if let session = model.selectedSession { PaneStatusStrip(session: session) }
                }
                if tab == .usage {
                    UsageView(usage: usage).background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .overlay(alignment: .top) { NoticeBanner(model: model) }
        }
        .navigationTitle("")
        .onChange(of: model.selectedID) { _, _ in tab = .sessions }
        .task { if !Bootstrap.isUnderTest { usage.start() } }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .principal) {
                MemorySummaryView(summary: model.summary, daemonConnected: model.daemonConnected)
            }
            ToolbarItem {
                Button {
                    if let cwd = DirectoryPicker.choose() { model.newSession(cwd: cwd) }
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New session in folder (Cmd-N)")
            }
        }
        .background(WindowFrameReader(initial: model.windowFrameForRestore) { model.windowFrame = $0 })
    }
}

// MARK: Toolbar

struct MemorySummaryView: View {
    let summary: MemorySummary
    let daemonConnected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: daemonConnected ? "circle.fill" : "circle")
                .font(.system(size: 7))
                .foregroundStyle(daemonConnected ? Palette.accent : .secondary)
                .help(daemonConnected ? "Connected to ccgovd" : "ccgovd not running: polling claude agents --json")
            stat(Formatting.bytes(summary.liveBytes), "live")
            stat("\(summary.asleep)", "asleep")
            stat(Formatting.bytes(summary.freedBytes), "freed")
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 6)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).fontWeight(.medium)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

enum Palette {
    static let accent = Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255)
}

// MARK: Sidebar

struct SidebarView: View {
    @ObservedObject var model: WorkspaceModel
    /// Project groups the user folded. Groups start expanded so every session in a project is visible.
    @State private var collapsed: Set<String> = []

    var body: some View {
        let rows = model.rows
        let sections = SidebarLayout.sections(rows)
        let maxBytes = rows.filter { $0.state != .hibernated }.map(\.rssBytes).max() ?? 0
        List(selection: Binding<String?>(
            get: { model.selectedID },
            set: { id in
                if let id, let session = rows.first(where: { $0.sessionId == id }) { model.open(session) }
            }
        )) {
            ForEach(sections) { section in
                Section(section.kind.rawValue) {
                    ForEach(section.entries) { entry in
                        switch entry {
                        case let .session(s):
                            SessionRow(session: s, maxBytes: maxBytes, model: model).tag(s.sessionId)
                        case let .project(path, name, sessions):
                            DisclosureGroup(isExpanded: Binding(
                                get: { !collapsed.contains(entry.id) },
                                set: { open in
                                    if open { collapsed.remove(entry.id) } else { collapsed.insert(entry.id) }
                                }
                            )) {
                                ForEach(sessions) { s in
                                    SessionRow(session: s, maxBytes: maxBytes, model: model, showProject: false)
                                        .tag(s.sessionId)
                                }
                            } label: {
                                HStack {
                                    Text(name).lineLimit(1)
                                    Text("\(sessions.count)").foregroundStyle(.secondary).monospacedDigit()
                                }
                                .help(path)
                                .contextMenu {
                                    Button("New Session in This Project") { model.newSession(cwd: path) }
                                }
                            }
                        }
                    }
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
    let maxBytes: UInt64
    @ObservedObject var model: WorkspaceModel
    var showProject = true

    var body: some View {
        HStack(spacing: 8) {
            StateDot(state: session.state, demoted: session.demoted)
            Text(SessionGrouping.displayName(session))
                .lineLimit(1)
                .foregroundStyle(isDim ? .secondary : .primary)
            if showProject, let project = SidebarLayout.secondaryText(session) {
                Text(project).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            if session.pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).help("Pinned")
            }
            Spacer(minLength: 6)
            trailing
        }
        .help(session.cwd)
        .contextMenu { RowMenu(session: session, model: model) }
    }

    private var isDim: Bool { session.state == .hibernated || session.demoted }

    @ViewBuilder private var trailing: some View {
        if session.state == .hibernated {
            Text(Formatting.elapsed(sinceMs: session.hibernatedAtMs ?? session.lastActivityMs,
                                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        } else if session.rssBytes > 0 {
            MemoryBar(fraction: SidebarLayout.memoryFraction(session, maxBytes: maxBytes))
                .help(Formatting.bytes(session.rssBytes))
        }
    }
}

struct StateDot: View {
    let state: SessionState
    let demoted: Bool

    var body: some View {
        Group {
            switch state {
            case .running:
                Image(systemName: "circle.fill").foregroundStyle(Palette.accent).symbolEffect(.pulse)
            case .blocked:
                Image(systemName: "circle.fill").foregroundStyle(Palette.accent)
            case .hibernated:
                Image(systemName: "moon.fill").foregroundStyle(.tertiary)
            case .idle, .unknown:
                Image(systemName: "circle").foregroundStyle(demoted ? .tertiary : .secondary)
            }
        }
        .font(.system(size: 8))
        .frame(width: 10)
    }
}

struct MemoryBar: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(.secondary).frame(width: max(2, 44 * fraction))
        }
        .frame(width: 44, height: 4)
    }
}

struct RowMenu: View {
    let session: SessionInfo
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Button("Open") { model.open(session) }
            .disabled(session.kind == .background)
        if model.canTakeOver(session) {
            Button("Take Over") { Task { await model.takeOver(session) } }
        }
        Button("New Session in This Project") { model.newSession(cwd: session.cwd) }
            .disabled(session.cwd.isEmpty)
        if session.ownedByApp {
            Button("Close Pane") { model.close(session.sessionId) }
        }
        Divider()
        Button(session.pinned ? "Unpin" : "Pin (never hibernate)") {
            Task { await model.setPinned(session, !session.pinned) }
        }
        Button("Hibernate Now") { Task { await model.hibernateNow(session) } }
            .disabled(session.state == .hibernated || session.kind == .background)
        Divider()
        Button("Reveal Folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
        }
        .disabled(session.cwd.isEmpty)
        Button("Copy Resume Command") {
            guard let line = model.resumeCommandLine(session) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line, forType: .string)
        }
    }
}

// MARK: Pane area

struct PaneArea: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ZStack {
            ForEach(model.panes.filter(\.hasProcess)) { pane in
                PaneView(pane: pane, isSelected: pane.id == model.selectedID)
            }
            if model.selectedID == nil { EmptyState(model: model) }
        }
    }
}

struct EmptyState: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Recents.top(model.rows)) { s in
                Button { model.open(s) } label: {
                    HStack(spacing: 10) {
                        StateDot(state: s.state, demoted: s.demoted)
                        Text(SessionGrouping.displayName(s)).font(.title3)
                        Spacer()
                        Text(Formatting.shortPath(s.cwd)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            }
            Button("New Session in Folder...") {
                if let cwd = DirectoryPicker.choose() { model.newSession(cwd: cwd) }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: 440)
        .padding()
    }
}

struct PaneStatusStrip: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            Text(SessionGrouping.displayName(session)).fontWeight(.medium)
            Button(Formatting.shortPath(session.cwd)) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
            }
            .buttonStyle(.link)
            .help("Reveal in Finder")
            Spacer()
            if session.rssBytes > 0 { Text(Formatting.bytes(session.rssBytes)) }
            if session.demoted { Text("bg").foregroundStyle(.secondary).help("Background CPU priority") }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

struct NoticeBanner: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Group {
            if let text = model.notice {
                HStack(spacing: 10) {
                    Text(text).font(.callout).lineLimit(3)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(6))
                    if model.notice == text { model.notice = nil }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
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
