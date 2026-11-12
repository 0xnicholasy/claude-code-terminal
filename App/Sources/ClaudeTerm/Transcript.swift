import Foundation

/// What a session's main thread is doing right now, read from the tail of its transcript.
struct TranscriptStatus: Equatable {
    struct PendingTool: Equatable {
        var id: String
        var name: String
        var summary: String
    }

    var pending: [PendingTool] = []
    var contextTokens: Int?
    var model: String?

    /// The last pending tool's summary, shown as the live activity line.
    var activity: String? { pending.last?.summary }

    private struct Line: Decodable {
        struct Message: Decodable {
            var model: String?
            var content: Content?
            var usage: Usage?
        }

        struct Usage: Decodable {
            var input_tokens: Int?
            var cache_read_input_tokens: Int?
            var cache_creation_input_tokens: Int?
        }

        enum Content: Decodable {
            case text(String)
            case blocks([Block])

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([Block].self)) }
            }
        }

        /// Tool input is arbitrary JSON, so only the few fields the summary needs are read.
        struct Input: Decodable {
            var file_path: String?
            var notebook_path: String?
            var command: String?
            var description: String?
        }

        struct Block: Decodable {
            var type: String
            var text: String?
            var id: String?
            var name: String?
            var tool_use_id: String?
            var input: Input?

            private enum CodingKeys: String, CodingKey { case type, text, id, name, tool_use_id, input }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try c.decode(String.self, forKey: .type)
                text = try? c.decode(String.self, forKey: .text)
                id = try? c.decode(String.self, forKey: .id)
                name = try? c.decode(String.self, forKey: .name)
                tool_use_id = try? c.decode(String.self, forKey: .tool_use_id)
                input = try? c.decode(Input.self, forKey: .input)
            }
        }

        var type: String
        var isSidechain: Bool?
        var isMeta: Bool?
        var message: Message?
    }

    /// Parses transcript JSONL (possibly just a file tail). Every line is decoded on its own, so a
    /// truncated first line or a garbled one is skipped instead of failing the whole parse.
    static func parse(_ data: Data) -> TranscriptStatus {
        var status = TranscriptStatus()
        let decoder = JSONDecoder()
        for raw in data.split(separator: 0x0A) {
            guard let line = try? decoder.decode(Line.self, from: raw), line.isSidechain != true,
                  line.isMeta != true else { continue }
            switch (line.type, line.message?.content) {
            case let ("user", content?):
                if case let .blocks(blocks) = content {
                    for id in blocks.filter({ $0.type == "tool_result" }).compactMap(\.tool_use_id) {
                        status.pending.removeAll { $0.id == id }
                    }
                }
                if isPrompt(content) { status.pending.removeAll() }
            case ("assistant", _):
                if case let .blocks(blocks)? = line.message?.content {
                    for b in blocks where b.type == "tool_use" {
                        guard let id = b.id, let name = b.name else { continue }
                        status.pending.append(PendingTool(id: id, name: name, summary: summary(name: name, input: b.input)))
                    }
                }
                guard let message = line.message, message.model != "<synthetic>" else { continue }
                if let model = message.model { status.model = model }
                if let u = message.usage {
                    status.contextTokens = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0)
                        + (u.cache_creation_input_tokens ?? 0)
                }
            default: continue
            }
        }
        return status
    }

    /// A real prompt is user text; tool results and "<command-name>" / "<ide_opened_file>" style
    /// wrappers are not. Each text block is checked on its own, so a wrapper block in front of the
    /// real prompt does not hide it.
    private static func isPrompt(_ content: Line.Content) -> Bool {
        switch content {
        case let .text(s): return isPromptText(s)
        case let .blocks(blocks):
            return blocks.contains { $0.type == "text" && isPromptText($0.text ?? "") }
        }
    }

    private static func isPromptText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.range(of: #"^<[A-Za-z][\w-]*[\s/>]"#, options: .regularExpression) == nil
    }

    private static func summary(name: String, input: Line.Input?) -> String {
        switch name {
        case "Edit", "Write", "Read", "NotebookEdit":
            guard let path = input?.file_path ?? input?.notebook_path, !path.isEmpty else { return name }
            return name + " " + (path as NSString).lastPathComponent
        case "Bash":
            guard let command = input?.command else { return name }
            let first = command.components(separatedBy: .newlines).first ?? command
            return "Bash: " + String(first.prefix(60))
        case "Task", "Agent":
            guard let description = input?.description, !description.isEmpty else { return name }
            return "Task: " + description
        default:
            if name.hasPrefix("mcp__") {
                let rest = name.dropFirst(5)
                if let r = rest.range(of: "__"), r.upperBound < rest.endIndex {
                    return rest[..<r.lowerBound] + ": " + rest[r.upperBound...]
                }
            }
            return name
        }
    }

    /// Share of the context window in use, for the sidebar ring; nil until a usage line is seen.
    var contextFraction: Double? {
        contextTokens.map { Double($0) / Double(Self.contextLimit(model: model, tokens: $0)) }
    }

    /// "Context: 132K of 200K (66%)" for the row's help text.
    var contextHelp: String? {
        guard let tokens = contextTokens else { return nil }
        func short(_ n: Int) -> String {
            Formatting.tokens(n).replacingOccurrences(of: #"\.0(?=[KMB])"#, with: "", options: .regularExpression)
        }
        let limit = Self.contextLimit(model: model, tokens: tokens)
        return "Context: \(short(tokens)) of \(short(limit)) (\(tokens * 100 / limit)%)"
    }

    /// No transcript field marks the 1M window, so more than 200K in use proves it.
    static func contextLimit(model: String?, tokens: Int) -> Int {
        if tokens > 200_000 { return 1_000_000 }
        return 200_000
    }
}

/// How full the context window is, for colouring the meter.
enum ContextLevel: Equatable {
    case normal, amber, red

    static func of(_ fraction: Double) -> ContextLevel {
        if fraction >= 0.85 { return .red }
        if fraction >= 0.70 { return .amber }
        return .normal
    }
}

/// Live per-session status for every running pane, from a 2 s mtime poll that re-parses only changed transcripts.
@MainActor
final class TranscriptStatusModel: ObservableObject {
    @Published private(set) var statuses: [String: TranscriptStatus] = [:]
    private let path: @Sendable (String) -> String?
    private let mtime: @Sendable (String) -> Date?
    private let read: @Sendable (String) -> Data?
    private var paths: [String: String] = [:]
    private var seen: [String: Date] = [:]
    /// Ticks left before a transcript that was not found is looked up again. A new session has no
    /// file until its first message, and each lookup lists every project folder.
    private var missBackoff: [String: Int] = [:]
    static let missRetryTicks = 5
    private var task: Task<Void, Never>?

    init(
        path: @escaping @Sendable (String) -> String? = { TranscriptReplies.transcriptPath(sessionId: $0) },
        mtime: @escaping @Sendable (String) -> Date? = {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        },
        read: @escaping @Sendable (String) -> Data? = { TranscriptReplies.tail($0, maxBytes: 256 * 1024) }
    ) {
        self.path = path
        self.mtime = mtime
        self.read = read
    }

    /// Starts the 2 s poll over the panes `panes()` returns each tick; only those with a process are read. Idempotent.
    func start(panes: @escaping @MainActor () -> [Pane]) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(panes().filter(\.hasProcess).map(\.id))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One poll step: drops closed ids, then re-parses each id whose transcript mtime changed.
    func refresh(_ ids: [String]) async {
        let open = Set(ids)
        paths = paths.filter { open.contains($0.key) }
        seen = seen.filter { open.contains($0.key) }
        missBackoff = missBackoff.filter { open.contains($0.key) }
        // Assign only on change: every @Published write re-renders the views observing this model.
        if statuses.keys.contains(where: { !open.contains($0) }) {
            statuses = statuses.filter { open.contains($0.key) }
        }
        for id in ids {
            let resolve = path, stat = mtime, load = read
            var p = paths[id]
            if p == nil {
                if let left = missBackoff[id], left > 0 {
                    missBackoff[id] = left - 1
                    continue
                }
                p = await Task.detached { resolve(id) }.value
                paths[id] = p
                missBackoff[id] = p == nil ? Self.missRetryTicks - 1 : nil
            }
            guard let p else { continue }
            let m = await Task.detached { stat(p) }.value
            // A resumed session's transcript can move to another project dir, so a vanished file re-resolves next tick.
            guard let m else {
                paths[id] = nil
                seen[id] = nil
                continue
            }
            guard m != seen[id] else { continue }
            // Mark the mtime seen only after a successful read, so a failed read is retried next tick.
            // Read and parse off the main actor; a busy transcript's tail is up to 256 KB of JSON.
            guard let parsed = await Task.detached(operation: { load(p).map(TranscriptStatus.parse) }).value
            else { continue }
            seen[id] = m
            if statuses[id] != parsed { statuses[id] = parsed }
        }
    }
}
