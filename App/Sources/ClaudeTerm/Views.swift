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
    @ObservedObject var clipboard: ClipboardModel
    @ObservedObject var transcripts: TranscriptStatusModel
    @StateObject private var git = GitStatusModel()
    @StateObject private var replies = RepliesModel()
    @AppStorage(RepliesModel.enabledKey) private var showReplies = true

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, statuses: transcripts.statuses)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            ZStack {
                // Panes stay mounted under the Usage tab so their terminals keep running untouched.
                VStack(spacing: 0) {
                    PaneArea(model: model, replies: showReplies && model.selectedID != nil ? replies : nil)
                    if let session = model.selectedSession { PaneStatusStrip(session: session, model: model) }
                }
                if model.tab == .usage {
                    UsageView(usage: usage, knownPaths: model.rows.map(\.cwd)).background(Palette.main)
                }
            }
            .background(Palette.main)
            .overlay(alignment: .bottom) { NoticeBanner(model: model) }
        }
        .toolbarBackground(Palette.main, for: .windowToolbar)
        .navigationTitle("")
        .onChange(of: model.selectedID) { _, _ in model.tab = .sessions }
        .task { if !Bootstrap.isUnderTest { usage.start() } }
        .onChange(of: model.selectedSession?.cwd, initial: true) { _, cwd in
            if !Bootstrap.isUnderTest { git.track(cwd) }
        }
        .onChange(of: showReplies ? model.selectedID : nil, initial: true) { _, id in
            if !Bootstrap.isUnderTest { replies.track(id) }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                TabSwitcher(tab: $model.tab)
                    .help([Shortcuts.hint("Sessions", Shortcuts.sessionsTab), Shortcuts.hint("Usage", Shortcuts.usageTab),
                           Shortcuts.hint("Switch", Shortcuts.toggleTab)].joined(separator: "\n"))
            }
            .plainBackground()
            ToolbarItem(placement: .principal) {
                // fixedSize: the toolbar must never truncate these to "US..." or pad them apart.
                HStack(spacing: 18) {
                    MemorySummaryView(summary: model.summary, daemonConnected: model.daemonConnected)
                    if let status = git.status { GitChip(status: status) }
                    QuotaChip(quota: usage.quota, costs: usage.costs, outlook: usage.outlook)
                }
                .fixedSize()
                .padding(.horizontal, 10)
            }
            .plainBackground()
            ToolbarItem {
                ClipboardButton(clipboard: clipboard)
            }
            ToolbarItem {
                Toggle(isOn: $showReplies) {
                    Label("Formatted Output", systemImage: "text.document")
                }
                .toggleStyle(.button)
                .help(Shortcuts.hint(showReplies ? "Formatted output on: Claude's markdown rendered in the pane. Turn off to stop reading the transcript"
                                                 : "Render Claude's markdown output in the pane", Shortcuts.replies))
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

extension ToolbarContent {
    /// Drops the glass capsule macOS 26 draws behind toolbar items, for the flat Claude app look.
    @ToolbarContentBuilder func plainBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Sessions / Usage switch drawn as two flat text tabs instead of a segmented control.
struct TabSwitcher: View {
    @Binding var tab: DetailTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DetailTab.allCases) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tab == t ? Palette.text : Palette.textTertiary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(tab == t ? Palette.rowSelected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

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

/// Colours taken from the Claude desktop app: warm charcoal in dark mode, warm off-white in light
/// mode, and Claude's clay orange as the one accent.
enum Palette {
    static let accent = Color(hex: 0xD97757)
    /// Window content behind the panes and the Usage tab.
    static let main = dynamic(light: 0xFAF9F5, dark: 0x262624)
    /// Sidebar column, one step darker than `main` in dark mode, as in the Claude app.
    static let sidebar = dynamic(light: 0xF3F1EA, dark: 0x1F1E1D)
    static let text = dynamic(light: 0x141413, dark: 0xF0EEE6)
    static let textSecondary = dynamic(light: 0x5E5D59, dark: 0xB7B5A9)
    static let textTertiary = dynamic(light: 0x8F8D86, dark: 0x85837B)
    /// Sidebar row fills: hover, and the selected row.
    static let rowHover = Color.primary.opacity(0.045)
    static let rowSelected = dynamic(light: 0xE8E5DA, dark: 0x30302E)
    /// Raised surfaces (cards, list containers) and their outline, tuned for both appearances.
    static let surface = Color.primary.opacity(0.045)
    static let hairline = Color.primary.opacity(0.08)
    /// Context ring warning colours, from the terminal palette's yellow and red.
    static let contextAmber = dynamic(light: 0xA87512, dark: 0xE3B26B)
    static let contextRed = dynamic(light: 0xB6412F, dark: 0xE06C5A)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
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
    /// Transcript status of open panes with a running claude, by session id.
    var statuses: [String: TranscriptStatus] = [:]
    /// Projects the user folded or unfolded, by project id. Without an entry, a project is expanded
    /// when it has a pane open or a session waiting, and folded otherwise, so the list stays short.
    @AppStorage("sidebar.projectExpansion") private var expansionJSON = "{}"

    var body: some View {
        let rows = model.rows
        let layout = SidebarLayout.projects(rows, paneOrder: model.panes.map(\.id))
        // A plain scroll stack instead of a sidebar List: List draws the system selection pill and
        // vibrancy, which cannot be restyled to the Claude app's flat, warm sidebar.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !layout.open.isEmpty { section("Open here", layout.open) }
                if !layout.other.isEmpty { section("Projects", layout.other) }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .background(Palette.sidebar)
        .overlay {
            if rows.isEmpty {
                Text("No sessions").foregroundStyle(Palette.textTertiary)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ projects: [SidebarProject]) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
        ForEach(projects) { group($0) }
    }

    @ViewBuilder private func group(_ project: SidebarProject) -> some View {
        let expanded = expansion(project)
        ProjectHeader(project: project, model: model, isExpanded: expanded.wrappedValue) {
            withAnimation(.easeOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
        }
        if expanded.wrappedValue {
            ForEach(project.sessions) { s in
                SessionRow(session: s, model: model, status: statuses[s.sessionId],
                           isSelected: s.sessionId == model.selectedID) {
                    model.open(s)
                }
            }
        }
    }

    private func expansion(_ project: SidebarProject) -> Binding<Bool> {
        Binding(
            get: { overrides[project.id] ?? (project.isOpen || project.waiting > 0) },
            set: { open in
                var o = overrides
                o[project.id] = open
                if let data = try? JSONEncoder().encode(o) { expansionJSON = String(decoding: data, as: UTF8.self) }
            }
        )
    }

    private var overrides: [String: Bool] {
        (try? JSONDecoder().decode([String: Bool].self, from: Data(expansionJSON.utf8))) ?? [:]
    }
}

struct ProjectHeader: View {
    let project: SidebarProject
    @ObservedObject var model: WorkspaceModel
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(project.isOpen ? Palette.text : Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if project.waiting > 0 {
                    Text("\(project.waiting)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Palette.accent))
                        .help("\(project.waiting) waiting for you")
                } else if hovering {
                    Text("\(project.sessions.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Palette.rowHover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, 2)
        .help(Formatting.shortPath(project.path) + "\nRight-click for a new session here")
        .contextMenu {
            Button("New Session in This Project") { model.newSession(cwd: project.path) }
                .disabled(project.path.isEmpty)
            Button("Reveal Folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
            }
            .disabled(project.path.isEmpty)
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo
    @ObservedObject var model: WorkspaceModel
    var status: TranscriptStatus?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shortcut = model.paneShortcut(session.sessionId)
        Button(action: action) {
            HStack(spacing: 8) {
                StateDot(state: session.state, demoted: session.demoted)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(SessionGrouping.displayName(session))
                            .font(.system(size: 13))
                            .foregroundStyle(nameColor)
                            .lineLimit(1)
                        if session.pinned {
                            Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Palette.textTertiary)
                        }
                    }
                    if isWaiting {
                        Text("Waiting for you").font(.system(size: 11)).foregroundStyle(Palette.accent)
                    } else if let activity {
                        Text(activity).font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                // Details stay out of the way until the row is hovered or selected.
                if hovering || isSelected { trailing }
                if let fraction = status?.contextFraction { ContextRing(fraction: fraction) }
                Text(shortcut ?? "")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 24, alignment: .trailing)
            }
            .padding(.leading, 20)
            .padding(.trailing, 6)
            .padding(.vertical, isWaiting || activity != nil ? 5 : 0)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(rowFill))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText(shortcut))
        .contextMenu { RowMenu(session: session, model: model) }
    }

    private var isWaiting: Bool { session.state == .blocked }
    /// What the session is doing right now; only while it is working. Between tool calls it reads
    /// "Working", so the row keeps its height instead of jumping on every tool start and finish.
    private var activity: String? {
        guard session.state == .running, let status else { return nil }
        return status.activity ?? "Working"
    }
    private var isDim: Bool { session.state == .hibernated || session.demoted }
    private var nameColor: Color {
        if isSelected || isWaiting { return Palette.text }
        return isDim ? Palette.textTertiary : Palette.textSecondary
    }
    private var rowFill: Color {
        if isSelected { return Palette.rowSelected }
        return hovering ? Palette.rowHover : .clear
    }

    private func helpText(_ shortcut: String?) -> String {
        var lines = [Formatting.shortPath(session.cwd), "State: \(stateText)"]
        if session.rssBytes > 0, session.state != .hibernated { lines.append("Memory: \(Formatting.bytes(session.rssBytes))") }
        if let context = status?.contextHelp { lines.append(context) }
        if !session.ownedByApp, session.kind == .interactive { lines.append("Running in another terminal") }
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
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.textTertiary)
                .fixedSize()
        } else if session.rssBytes > 0 {
            Text(Formatting.bytes(session.rssBytes))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.textTertiary)
                .fixedSize()
        }
    }
}

/// How full the session's context window is, coloured amber from 70% and red from 85%.
struct ContextRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Palette.hairline, lineWidth: 2)
            Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .padding(.horizontal, 1)
    }

    private var color: Color {
        switch ContextLevel.of(fraction) {
        case .normal: Palette.textTertiary
        case .amber: Palette.contextAmber
        case .red: Palette.contextRed
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
                    .frame(width: 6, height: 6)
            case .blocked:
                Image(systemName: "bell.fill").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .symbolEffect(.pulse)
            case .hibernated:
                Image(systemName: "moon.fill").font(.system(size: 8)).foregroundStyle(Palette.textTertiary)
            case .idle, .unknown:
                Circle().strokeBorder(Palette.textTertiary.opacity(demoted ? 0.5 : 1), lineWidth: 1)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 12, height: 12)
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

/// With Formatted Output on (`replies` set), the conversation fills the pane and the live terminal
/// shrinks to a strip at the bottom for typing, permission prompts and menus. The terminals stay in
/// the same place in the view tree either way, so toggling only resizes them; it never restarts them.
struct PaneArea: View {
    @ObservedObject var model: WorkspaceModel
    var replies: RepliesModel?

    var body: some View {
        VStack(spacing: 0) {
            if let replies {
                ConversationView(replies: replies)
                Divider()
            }
            ZStack {
                ForEach(model.panes.filter(\.hasProcess)) { pane in
                    PaneView(pane: pane, isSelected: pane.id == model.selectedID)
                }
                if model.selectedID == nil { EmptyState(model: model) }
            }
            .frame(height: replies == nil ? nil : Self.stripHeight)
        }
    }

    /// About 16 rows: enough for Claude Code's input box, status line and a permission prompt.
    static let stripHeight: CGFloat = 300
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
            if session.state == .blocked {
                Label("Waiting for your answer", systemImage: "bell.fill")
                    .foregroundStyle(Palette.accent)
                    .fontWeight(.semibold)
            }
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
        .background(session.state == .blocked ? Palette.accent.opacity(0.12) : .clear)
        .background(Palette.main)
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
