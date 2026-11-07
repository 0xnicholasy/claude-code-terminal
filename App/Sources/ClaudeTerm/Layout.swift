import Foundation

struct LayoutFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct PaneRecord: Codable, Equatable, Sendable {
    var sessionId: String
    var cwd: String
    var title: String
}

struct WindowRecord: Codable, Equatable, Sendable {
    var panes: [PaneRecord]
    var selected: String?
    var frame: LayoutFrame?
}

struct LayoutFile: Codable, Equatable, Sendable {
    var version: Int = 1
    var windows: [WindowRecord] = []
}

/// Reads and writes `layout.json`. Writes are atomic; a corrupt file is moved to `layout.json.bad`.
struct LayoutStore: Sendable {
    enum LoadResult: Equatable {
        case empty
        case loaded(LayoutFile)
        case recoveredCorrupt
    }

    let url: URL

    init(url: URL) { self.url = url }

    /// `CCTERM_LAYOUT_PATH` override, else `~/Library/Application Support/ClaudeTerm/layout.json`.
    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let p = environment["CCTERM_LAYOUT_PATH"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClaudeTerm/layout.json")
    }

    func load() -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        do {
            return .loaded(try JSONDecoder().decode(LayoutFile.self, from: data))
        } catch {
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            return .recoveredCorrupt
        }
    }

    func save(_ layout: LayoutFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(layout).write(to: url, options: .atomic)
    }
}
