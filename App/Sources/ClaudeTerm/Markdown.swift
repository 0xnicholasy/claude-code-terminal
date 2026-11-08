import CCProtocol
import Foundation
import SwiftUI

// Formatted replies: the selected session's recent Claude replies, read from its transcript
// (~/.claude/projects/<project>/<session id>.jsonl) and rendered as markdown beside the terminal.
// Nothing runs while the panel is off.

/// Block-level markdown, enough for Claude Code replies: headings, lists, fenced code, quotes,
/// tables, rules and paragraphs. Inline syntax is left to AttributedString.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(indent: Int, marker: String, text: String)
    case code(language: String, text: String)
    case quote(String)
    case table([[String]])
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces),
                                    text: body.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
            } else if let level = Self.headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level + 1))))
            } else if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            } else if trimmed.hasPrefix("|"), i + 1 < lines.count, Self.isTableDivider(lines[i + 1]) {
                flush()
                var rows = [Self.cells(trimmed)]
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(Self.cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(rows))
                continue
            } else if let item = Self.listItem(line) {
                flush()
                blocks.append(item)
            } else {
                paragraph.append(trimmed)
            }
            i += 1
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " }.count / 2
        let s = line.drop { $0 == " " }
        for bullet in ["- ", "* ", "+ "] where s.hasPrefix(bullet) {
            return .listItem(indent: indent, marker: "\u{2022}", text: String(s.dropFirst(2)))
        }
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = s.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .listItem(indent: indent, marker: digits + ".", text: String(rest.dropFirst(2)))
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var parts = row.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}

/// One conversation entry: a user prompt, or Claude's reply text for that prompt (tool calls left out).
struct Reply: Equatable, Identifiable {
    var id: String
    var text: String
    var date: Date?
    var isPrompt = false
}

enum TranscriptReplies {
    private struct Line: Decodable {
        struct Message: Decodable {
            var role: String?
            var content: Content?
        }

        enum Content: Decodable {
            case text(String)
            case blocks([Block])

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([Block].self)) }
            }
        }

        struct Block: Decodable {
            var type: String
            var text: String?
        }

        var type: String
        var uuid: String?
        var timestamp: String?
        var isSidechain: Bool?
        var isMeta: Bool?
        var message: Message?
    }

    /// The last `limit` entries, oldest first. Each real user prompt is an entry, followed by one
    /// reply entry joining all of Claude's text until the next prompt; tool results and sidechain
    /// (subagent) lines are skipped. Command and reminder wrappers ("<command-name>...") are not prompts.
    static func parse(_ data: Data, limit: Int = 40) -> [Reply] {
        var entries: [Reply] = []
        var current: Reply?
        let decoder = JSONDecoder()
        func prompt(_ text: String, _ line: Line) {
            if let c = current { entries.append(c) }
            current = nil
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.range(of: #"^<[a-z][a-z-]*>"#, options: .regularExpression) == nil else { return }
            entries.append(Reply(id: line.uuid ?? UUID().uuidString, text: t,
                                 date: line.timestamp.flatMap(ClaudeUsageParser.date), isPrompt: true))
        }
        for raw in data.split(separator: 0x0A) {
            guard let line = try? decoder.decode(Line.self, from: raw), line.isSidechain != true,
                  line.isMeta != true else { continue }
            switch (line.type, line.message?.content) {
            case let ("user", .text(text)?):
                prompt(text, line)
            case let ("user", .blocks(blocks)?) where blocks.contains(where: { $0.type == "text" }):
                prompt(blocks.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n"), line)
            case let ("assistant", .blocks(blocks)?):
                let text = blocks.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let date = line.timestamp.flatMap(ClaudeUsageParser.date)
                if var c = current {
                    c.text += "\n\n" + text
                    c.date = date ?? c.date
                    current = c
                } else {
                    current = Reply(id: line.uuid ?? UUID().uuidString, text: text, date: date)
                }
            default: continue
            }
        }
        if let c = current { entries.append(c) }
        return Array(entries.suffix(limit))
    }

    static var projectsDir: String { NSHomeDirectory() + "/.claude/projects" }

    static func transcriptPath(sessionId: String, projectsDir: String = projectsDir) -> String? {
        guard SessionID.isValid(sessionId),
              let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return nil }
        return dirs.lazy.map { projectsDir + "/" + $0 + "/" + sessionId + ".jsonl" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The last `maxBytes` of the file, starting at a line boundary.
    static func tail(_ path: String, maxBytes: UInt64 = 3 * 1024 * 1024) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let start = size > maxBytes ? size - maxBytes : 0
        try? h.seek(toOffset: start)
        guard var data = try? h.readToEnd() else { return nil }
        if start > 0, let nl = data.firstIndex(of: 0x0A) { data = data[data.index(after: nl)...] }
        return data
    }
}

@MainActor
final class RepliesModel: ObservableObject {
    static let enabledKey = "formattedReplies"
    @Published private(set) var replies: [Reply] = []
    @Published private(set) var sessionId: String?
    private var task: Task<Void, Never>?

    /// Watches one session's transcript (mtime check every 1.5 s, re-parse only on change); nil stops.
    func track(_ sessionId: String?) {
        guard sessionId != self.sessionId else { return }
        self.sessionId = sessionId
        task?.cancel()
        task = nil
        replies = []
        guard let sessionId else { return }
        task = Task { [weak self] in
            var path: String?
            var seen: Date?
            while !Task.isCancelled {
                if path == nil {
                    path = await Task.detached { TranscriptReplies.transcriptPath(sessionId: sessionId) }.value
                }
                if let p = path,
                   let mtime = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
                   mtime != seen {
                    seen = mtime
                    let parsed = await Task.detached { TranscriptReplies.tail(p).map { TranscriptReplies.parse($0) } ?? [] }.value
                    guard !Task.isCancelled, let self, self.sessionId == sessionId else { return }
                    self.replies = parsed
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

/// The formatted conversation shown in the pane while Formatted Output is on. Replies render as
/// markdown; prompts and plain-text replies stay plain.
struct ConversationView: View {
    @ObservedObject var replies: RepliesModel

    static func isSafeLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    var body: some View {
        Group {
            if replies.replies.isEmpty {
                Text("No conversation yet.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(replies.replies) { entry in
                                EntryView(entry: entry).id(entry.id)
                            }
                        }
                        .frame(maxWidth: 820, alignment: .leading)
                        .padding(.horizontal, 22).padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: replies.replies.last?.id) { _, id in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        // Reply text is model output, so a link in it is untrusted: open only web links.
        .environment(\.openURL, OpenURLAction { url in
            ConversationView.isSafeLink(url) ? .systemAction : .discarded
        })
    }
}

struct EntryView: View {
    let entry: Reply

    var body: some View {
        Group {
            if entry.isPrompt {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{203A}").font(.title3).foregroundStyle(Palette.accent)
                    Text(entry.text).lineLimit(8).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface))
            } else {
                MarkdownText(source: entry.text)
            }
        }
        .textSelection(.enabled)
    }
}

struct MarkdownText: View {
    let source: String

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text).font(level == 1 ? .title2 : level == 2 ? .title3 : .headline).fontWeight(.semibold)
                .padding(.top, 4)
        case let .paragraph(text):
            inline(text)
        case let .listItem(indent, marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .code(_, text):
            Text(text).font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface))
        case let .quote(text):
            inline(text).foregroundStyle(.secondary).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.accent).frame(width: 2) }
        case let .table(rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { n, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell).fontWeight(n == 0 ? .semibold : .regular)
                            }
                        }
                        if n == 0 { Divider() }
                    }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.hairline))
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        // Text does not style inline code on its own: monospaced, in the accent colour.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.body, design: .monospaced)
            attributed[run.range].foregroundColor = Palette.accent
        }
        return Text(attributed)
    }
}
