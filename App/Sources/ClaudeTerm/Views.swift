import AppKit
import CCProtocol
import GhosttyTerminal
import SwiftUI
import UniformTypeIdentifiers

enum DetailTab: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case usage = "Usage"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var usage: UsageModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            ZStack {
                // Panes stay mounted under the Usage tab so their terminals keep running untouched.
                VStack(spacing: 0) {
                    PaneArea(model: model)
                    if let session = model.selectedSession { PaneStatusStrip(session: session, model: model) }
                }
                if model.tab == .usage {
                    UsageView(usage: usage).background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .overlay(alignment: .bottom) { NoticeBanner(model: model) }
        }
        .navigationTitle("")
        .onChange(of: model.selectedID) { _, _ in model.tab = .sessions }
        .task { if !Bootstrap.isUnderTest { usage.start() } }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: $model.tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help([Shortcuts.hint("Sessions", Shortcuts.sessionsTab), Shortcuts.hint("Usage", Shortcuts.usageTab),
                       Shortcuts.hint("Switch", Shortcuts.toggleTab)].joined(separator: "\n"))
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 16) {
                    MemorySummaryView(summary: model.summary, daemonConnected: model.daemonConnected)
                    Divider().frame(height: 14)
                    QuotaChip(quota: usage.quota)
                }
                .padding(.horizontal, 8)
            }
            ToolbarItem {
                Button {
                    if let cwd = DirectoryPicker.choose() { model.newSession(cwd: cwd) }
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help(Shortcuts.hint("New session in a folder", Shortcuts.newSession))
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
        HStack(spacing: 12) {
            Circle()
                .fill(daemonConnected ? Palette.accent : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .help(daemonConnected ? "Connected to ccgovd" : "ccgovd not running: polling claude agents --json")
            stat("memorychip", Formatting.bytes(summary.liveBytes), "Memory used by live sessions")
            stat("moon", "\(summary.asleep)", "Hibernated sessions")
            if summary.freedBytes > 0 {
                stat("arrow.down.circle", Formatting.bytes(summary.freedBytes), "Memory freed by hibernation since launch")
            }
        }
        .font(.callout.monospacedDigit())
    }

    private func stat(_ icon: String, _ value: String, _ help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary).imageScale(.small)
            Text(value).fontWeight(.medium)
        }
        .help(help)
    }
}

enum Palette {
    static let accent = Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255)
    /// Raised surfaces (cards, list containers) and their outline, tuned for both appearances.
    static let surface = Color.primary.opacity(0.045)
    static let hairline = Color.primary.opacity(0.08)
}

/// Rounded container used by the empty state and the Usage tab.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }
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
                Section {
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
                                HStack(spacing: 6) {
                                    Image(systemName: "folder").foregroundStyle(.secondary).imageScale(.small)
                                    Text(name).fontWeight(.medium).lineLimit(1)
                                    Spacer()
                                    Text("\(sessions.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                }
                                .help(path + "\nRight-click for a new session here")
                                .contextMenu {
                                    Button("New Session in This Project") { model.newSession(cwd: path) }
                                }
                            }
                        }
                    }
                } header: {
                    Text(section.kind.rawValue)
                        .help(Shortcuts.hint("Move through sessions", Shortcuts.nextSession + " / " + Shortcuts.previousSession))
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "terminal").font(.title2).foregroundStyle(.tertiary)
                    Text("No sessions").foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo
    let maxBytes: UInt64
    @ObservedObject var model: WorkspaceModel
    var showProject = true

    var body: some View {
        let shortcut = model.paneShortcut(session.sessionId)
        HStack(spacing: 9) {
            StateDot(state: session.state, demoted: session.demoted)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(SessionGrouping.displayName(session))
                        .lineLimit(1)
                        .foregroundStyle(isDim ? .secondary : .primary)
                    if session.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
                if showProject, let project = SidebarLayout.secondaryText(session) {
                    Text(project).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                trailing
                if let shortcut {
                    Text(shortcut).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
                }
            }
        }
        .padding(.vertical, 2)
        .help(helpText(shortcut))
        .contextMenu { RowMenu(session: session, model: model) }
    }

    private var isDim: Bool { session.state == .hibernated || session.demoted }

    private func helpText(_ shortcut: String?) -> String {
        var lines = [session.cwd, "State: \(stateText)"]
        if session.rssBytes > 0, session.state != .hibernated { lines.append("Memory: \(Formatting.bytes(session.rssBytes))") }
        if let shortcut { lines.append(Shortcuts.hint("Show pane", shortcut)) }
        lines.append("Right-click for more actions")
        return lines.joined(separator: "\n")
    }

    private var stateText: String {
        switch session.state {
        case .running: "working"
        case .blocked: "waiting for you"
        case .hibernated: "hibernated"
        case .idle: session.demoted ? "idle, background priority" : "idle"
        case .unknown: "unknown"
        }
    }

    @ViewBuilder private var trailing: some View {
        if session.state == .hibernated {
            Text(Formatting.elapsed(sinceMs: session.hibernatedAtMs ?? session.lastActivityMs,
                                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        } else if session.rssBytes > 0 {
            // Text only: a bar beside it cost the name its width. Relative size shows as text weight.
            Text(Formatting.bytes(session.rssBytes))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(SidebarLayout.memoryFraction(session, maxBytes: maxBytes) > 0.75 ? .secondary : .tertiary)
                .fixedSize()
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
                Circle().fill(Palette.accent).symbolEffect(.pulse)
            case .blocked:
                Circle().fill(Palette.accent)
                    .overlay(Circle().strokeBorder(Palette.accent.opacity(0.35), lineWidth: 2).scaleEffect(1.8))
            case .hibernated:
                Image(systemName: "moon.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
            case .idle, .unknown:
                Circle().strokeBorder(demoted ? Color.secondary.opacity(0.4) : Color.secondary, lineWidth: 1.2)
            }
        }
        .frame(width: 7, height: 7)
        .frame(width: 12)
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
        let recents = Recents.top(model.rows, limit: 5)
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            if !recents.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(recents.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider().padding(.leading, 34) }
                        RecentRow(session: s) { model.open(s) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
            }
            HStack(spacing: 10) {
                Button {
                    if let cwd = DirectoryPicker.choose() { model.newSession(cwd: cwd) }
                } label: {
                    Label("New Session", systemImage: "plus").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .controlSize(.large)
                .help(Shortcuts.hint("New session in a folder", Shortcuts.newSession))
                Button("Usage") { model.tab = .usage }
                    .controlSize(.large)
                    .help(Shortcuts.hint("Plan quota and cost", Shortcuts.usageTab))
            }
        }
        .frame(maxWidth: 460)
        .padding(32)
    }
}

struct RecentRow: View {
    let session: SessionInfo
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StateDot(state: session.state, demoted: session.demoted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SessionGrouping.displayName(session)).fontWeight(.medium).lineLimit(1)
                    Text(Formatting.shortPath(session.cwd)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let ago = Formatting.elapsed(sinceMs: session.lastActivityMs,
                                                nowMs: Int64(Date().timeIntervalSince1970 * 1000)) {
                    Text(ago).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(hovering ? Palette.hairline : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(SessionGrouping.displayName(session))\n\(session.cwd)")
    }
}

struct PaneStatusStrip: View {
    let session: SessionInfo
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 10) {
            if let pos = model.selectedPanePosition, pos.count > 1 {
                HStack(spacing: 2) {
                    iconButton("chevron.left", Shortcuts.hint("Previous pane", Shortcuts.previousPane)) {
                        model.cyclePane(by: -1)
                    }
                    Text("\(pos.index) of \(pos.count)").foregroundStyle(.secondary)
                        .help("Panes \(Shortcuts.cmd)1 to \(Shortcuts.cmd)8, last pane \(Shortcuts.cmd)9, cycle Ctrl-Tab")
                    iconButton("chevron.right", Shortcuts.hint("Next pane", Shortcuts.nextPane)) {
                        model.cyclePane(by: 1)
                    }
                }
                Divider().frame(height: 12)
            }
            StateDot(state: session.state, demoted: session.demoted)
            Text(SessionGrouping.displayName(session)).fontWeight(.medium)
            Button(Formatting.shortPath(session.cwd)) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .truncationMode(.middle)
            .help("Reveal in Finder")
            Spacer(minLength: 8)
            if session.demoted {
                Text("background priority").foregroundStyle(.tertiary).help("ccgovd lowered this session's CPU priority")
            }
            if session.rssBytes > 0 { Text(Formatting.bytes(session.rssBytes)).foregroundStyle(.secondary) }
            iconButton("plus", Shortcuts.hint("New session in this project", Shortcuts.newInProject)) {
                model.newSessionInCurrentProject()
            }
            iconButton("xmark", Shortcuts.hint("Close pane", Shortcuts.closePane)) { model.close(session.sessionId) }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct NoticeBanner: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Group {
            if let text = model.notice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Palette.accent)
                    Text(text).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Button { model.notice = nil } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 520)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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

/// Cmd-click on a link in a pane. The embedded library reports the URL to the view's delegate
/// (a `TerminalViewState`) and does not open it itself, so the app opens it here.
extension TerminalViewState: @retroactive TerminalSurfaceOpenURLDelegate {
    public func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        guard let target = LinkPolicy.url(url) else { return }
        guard target.isFileURL else {
            NSWorkspace.shared.open(target)
            return
        }
        // Terminal output is untrusted: a printed path to an app, script or binary must never be
        // launched by a click. Only plain documents open; everything else is shown in Finder.
        let values = try? target.resourceValues(forKeys: [.contentTypeKey, .isExecutableKey, .isDirectoryKey, .isPackageKey])
        switch LinkPolicy.fileAction(
            type: values?.contentType,
            isExecutable: values?.isExecutable ?? false,
            isDirectory: values?.isDirectory ?? false,
            isPackage: values?.isPackage ?? false
        ) {
        case .open: NSWorkspace.shared.open(target)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
}

enum LinkPolicy {
    /// Web, mail and file links only; other schemes could launch arbitrary apps from terminal output.
    static let schemes: Set<String> = ["http", "https", "mailto", "file"]

    static func url(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        guard let u = URL(string: text), let scheme = u.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        return u
    }

    enum FileAction: Equatable { case open, reveal }

    /// Document types that are safe to hand to their default app.
    static let openableTypes: [UTType] = [.image, .movie, .audio, .pdf, .plainText, .json]
    /// Types that run code when opened. Checked first because scripts also conform to plain text.
    static let launchableTypes: [UTType] = [.executable, .application, .applicationBundle, .script, .shellScript]

    /// Open a local file only when it is a plain document; reveal anything that could run code,
    /// any folder or bundle, and any file whose type is unknown.
    static func fileAction(type: UTType?, isExecutable: Bool, isDirectory: Bool, isPackage: Bool) -> FileAction {
        guard let type, !isDirectory, !isPackage, !isExecutable else { return .reveal }
        if launchableTypes.contains(where: type.conforms(to:)) { return .reveal }
        return openableTypes.contains(where: type.conforms(to:)) ? .open : .reveal
    }
}
