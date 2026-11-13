import AppKit
import SwiftUI

/// Config tab (T22): MCP servers, skills, agents and hooks for the selected session's project.
/// Read-only (D3). Clicking a skill, agent or hook row reveals its file in Finder (D14).
struct ConfigView: View {
    let project: String?
    @ObservedObject var mcp: McpListModel
    /// nil while the scan runs, so the sections read "Scanning", not "None".
    @State private var items: [ConfigItem]?

    var body: some View {
        if let project {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    mcpSection(project)
                    section("Skills", kind: .skill)
                    section("Agents", kind: .agent)
                    section("Hooks", kind: .hook)
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .task(id: project) {
                items = nil
                let home = NSHomeDirectory()
                let scanned = await Task.detached { ConfigScanner.scan(home: home, project: project) }.value
                guard !Task.isCancelled else { return } // a scan of the previous project finishing late
                items = scanned
            }
        } else {
            Text("Select a session")
                .font(.system(size: 13))
                .foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: MCP

    /// `claude mcp list` starts every configured server, including ones from the project's
    /// `.mcp.json`, so it runs only when the user clicks Check or Refresh, never on open.
    @ViewBuilder private func mcpSection(_ project: String) -> some View {
        let state = mcp.states[project]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "MCP servers")
                Spacer()
                if state == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(state == nil ? "Check" : "Refresh") {
                        Task { await mcp.load(project: project, force: true) }
                    }
                    .controlSize(.small)
                    .help("Runs claude mcp list in this project. It starts each server to check its health.")
                }
            }
            Card(padding: 0) {
                switch state {
                case nil:
                    EmptyLine(text: "Not checked yet")
                case .loading:
                    EmptyLine(text: "Checking servers")
                case .failed(let message):
                    EmptyLine(text: message)
                case .loaded(let servers) where servers.isEmpty:
                    EmptyLine(text: "None")
                case .loaded(let servers):
                    VStack(spacing: 0) {
                        // Keyed by position: a server can be listed twice (same name).
                        ForEach(Array(servers.enumerated()), id: \.offset) { _, s in
                            ConfigRow(name: s.name, detail: Self.label(s.status), scope: s.scope?.rawValue,
                                      clickable: false)
                        }
                    }
                }
            }
        }
    }

    static func label(_ status: McpServer.Status) -> String {
        switch status {
        case .connected: "Connected"
        case .failed: "Failed to connect"
        case .needsAuth: "Needs authentication"
        case .unknown: "Status unknown"
        }
    }

    // MARK: Skills, agents, hooks

    @ViewBuilder private func section(_ title: String, kind: ConfigItem.Kind) -> some View {
        let rows = (items ?? []).filter { $0.kind == kind }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: title)
            Card(padding: 0) {
                if items == nil {
                    EmptyLine(text: "Scanning")
                } else if rows.isEmpty {
                    EmptyLine(text: "None")
                } else {
                    VStack(spacing: 0) {
                        // Keyed by position: two identical hooks in one file share an id.
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                            } label: {
                                ConfigRow(name: item.name, detail: item.detail, scope: item.scope.rawValue,
                                          warning: item.unreadable)
                            }
                            .buttonStyle(.plain)
                            .help(Formatting.shortPath(item.path))
                        }
                    }
                }
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
    }
}

private struct EmptyLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}

private struct ConfigRow: View {
    let name: String
    let detail: String
    let scope: String?
    var warning = false
    var clickable = true
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13)).foregroundStyle(Palette.text).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(warning ? Palette.contextRed : Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let scope {
                Text(scope)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover && clickable ? Palette.rowHover : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
