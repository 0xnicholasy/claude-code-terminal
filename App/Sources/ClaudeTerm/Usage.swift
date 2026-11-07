import Darwin
import Foundation

// Usage tab: plan quota from `codexbar` and API-equivalent cost from `ccusage`. Both are optional
// user-installed tools; the app only reads their output and never talks to an Anthropic API itself.

struct QuotaWindow: Equatable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?
    var resetText: String?
    /// Where usage "should" be at this point in the window if spread evenly (codexbar pace).
    var expectedPercent: Double?
    var paceSummary: String?
}

struct QuotaSnapshot: Equatable {
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    var updatedAt: Date?
}

enum CodexbarParser {
    private struct Entry: Decodable {
        var usage: Usage?
        var pace: [String: Pace]?
    }

    private struct Usage: Decodable {
        var primary: Window?
        var secondary: Window?
        var updatedAt: String?
    }

    private struct Window: Decodable {
        var usedPercent: Double?
        var windowMinutes: Int?
        var resetsAt: String?
        var resetDescription: String?
        var isSyntheticPlaceholder: Bool?
    }

    private struct Pace: Decodable {
        var expectedUsedPercent: Double?
        var summary: String?
    }

    /// Output of `codexbar usage --provider claude --json`. A window marked as a synthetic placeholder
    /// carries no real number, so it is reported as missing rather than as 0%.
    static func parse(_ data: Data) -> QuotaSnapshot? {
        guard let entry = try? JSONDecoder().decode([Entry].self, from: data).first, let usage = entry.usage else { return nil }
        let iso = ISO8601DateFormatter()
        func window(_ w: Window?, pace: Pace?) -> QuotaWindow? {
            guard let w, w.isSyntheticPlaceholder != true, let used = w.usedPercent else { return nil }
            return QuotaWindow(usedPercent: used, windowMinutes: w.windowMinutes ?? 0,
                               resetsAt: w.resetsAt.flatMap(iso.date(from:)), resetText: w.resetDescription,
                               expectedPercent: pace?.expectedUsedPercent, paceSummary: pace?.summary)
        }
        return QuotaSnapshot(fiveHour: window(usage.primary, pace: entry.pace?["primary"]),
                             weekly: window(usage.secondary, pace: entry.pace?["secondary"]),
                             updatedAt: usage.updatedAt.flatMap(iso.date(from:)))
    }
}

/// Daily API-equivalent cost in USD, keyed by local date "yyyy-MM-dd".
struct CostHistory: Equatable {
    var days: [String: Double]

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func monthTotal(now: Date, calendar: Calendar = .current) -> Double {
        let prefix = String(Self.dayKey(now, calendar: calendar).prefix(8)) // "yyyy-MM-"
        return days.filter { $0.key.hasPrefix(prefix) }.reduce(0) { $0 + $1.value }
    }

    func today(now: Date, calendar: Calendar = .current) -> Double {
        days[Self.dayKey(now, calendar: calendar)] ?? 0
    }

    /// The last `count` days ending today, oldest first, with 0 for days without usage.
    func recent(_ count: Int, now: Date, calendar: Calendar = .current) -> [(day: String, cost: Double)] {
        (0..<count).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let key = Self.dayKey(d, calendar: calendar)
            return (key, days[key] ?? 0)
        }
    }
}

enum CostParser {
    /// `ccusage daily --json`: {"daily": [{"date": "2026-11-01", "totalCost": 12.3}, ...]}.
    static func ccusageDaily(_ data: Data) -> [String: Double]? {
        struct Out: Decodable {
            struct Day: Decodable { var date: String; var totalCost: Double }
            var daily: [Day]
        }
        guard let out = try? JSONDecoder().decode(Out.self, from: data) else { return nil }
        return Dictionary(out.daily.map { ($0.date, $0.totalCost) }, uniquingKeysWith: +)
    }

    /// A plain {"yyyy-MM-dd": cost} ledger, as kept by a ccusage-based status line.
    static func ledger(_ data: Data) -> [String: Double]? {
        try? JSONDecoder().decode([String: Double].self, from: data)
    }

    /// A ccusage blocks cache with a `todayCost` field (status line cache).
    static func todayCost(_ data: Data) -> Double? {
        struct Out: Decodable { var todayCost: Double? }
        return (try? JSONDecoder().decode(Out.self, from: data))?.todayCost
    }
}

enum SafeFile {
    /// Reads a small file only when it and its parent directory belong to this user and it is a regular
    /// file (not a symlink, FIFO or device) under `maxBytes`. Some inputs live under the shared `/tmp`, where
    /// another local user could plant a file or a FIFO that would block the read.
    static func read(_ url: URL, maxBytes: Int = 4 * 1024 * 1024) -> Data? {
        var st = stat(), dir = stat()
        let uid = getuid()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == uid, st.st_size <= maxBytes,
              lstat(url.deletingLastPathComponent().path, &dir) == 0, (dir.st_mode & S_IFMT) == S_IFDIR, dir.st_uid == uid
        else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var fst = stat()
        guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG, fst.st_ino == st.st_ino else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: maxBytes)
    }
}

enum UsageTools {
    static var home: String { NSHomeDirectory() }
    /// GUI apps do not inherit the login PATH; these are the usual install locations.
    static var searchPath: String {
        ["\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin"].joined(separator: ":")
    }

    static func find(_ name: String, override key: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env[key], FileManager.default.isExecutableFile(atPath: p) { return p }
        return searchPath.split(separator: ":").map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let ledgerURL = URL(fileURLWithPath: home + "/.cache/claude-statusline/ccusage-daily.json")
    static let todayCacheURL = URL(fileURLWithPath: "/tmp/claude/statusline-ccusage-cache.json")
    static var ownCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeTerm/ccusage-daily.json")
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var quota: QuotaSnapshot?
    @Published private(set) var costs: CostHistory?
    @Published private(set) var quotaMissingTool = false
    @Published private(set) var costMissingTool = false
    @Published private(set) var costIsRefreshing = false

    private var task: Task<Void, Never>?
    private var lastCostScan: Date?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func refresh() async {
        await refreshQuota()
        await refreshCosts()
    }

    private func refreshQuota() async {
        guard let tool = UsageTools.find("codexbar", override: "CCTERM_CODEXBAR_PATH") else {
            quotaMissingTool = true
            return
        }
        quotaMissingTool = false
        if let data = await ProcessRunner.run(tool, ["usage", "--provider", "claude", "--json"], timeout: 40),
           let snap = CodexbarParser.parse(data) {
            quota = snap
        }
    }

    /// Prefers a ledger a ccusage status line already keeps (no second multi-minute scan); otherwise
    /// runs `ccusage daily` for this month at most every 30 minutes and caches the result.
    private func refreshCosts() async {
        var days: [String: Double] = [:]
        if let data = SafeFile.read(UsageTools.ledgerURL), let ledger = CostParser.ledger(data) {
            days = ledger
            if let t = SafeFile.read(UsageTools.todayCacheURL), let today = CostParser.todayCost(t) {
                days[CostHistory.dayKey(Date())] = today
            }
            costs = CostHistory(days: days)
            costMissingTool = false
            return
        }
        if let data = SafeFile.read(UsageTools.ownCacheURL), let cached = CostParser.ccusageDaily(data) {
            costs = CostHistory(days: cached)
        }
        if let last = lastCostScan, Date().timeIntervalSince(last) < 30 * 60 { return }
        guard let tool = UsageTools.find("ccusage", override: "CCTERM_CCUSAGE_PATH") else {
            costMissingTool = costs == nil
            return
        }
        lastCostScan = Date()
        costIsRefreshing = true
        defer { costIsRefreshing = false }
        let since = String(CostHistory.dayKey(Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date())
            .replacingOccurrences(of: "-", with: ""))
        // ccusage is a bun/node script: run it through env so its interpreter is found on the search path.
        guard let data = await ProcessRunner.run("/usr/bin/env", ["PATH=\(UsageTools.searchPath)", tool, "daily", "--json", "--since", since],
                                                 timeout: 300),
              let parsed = CostParser.ccusageDaily(data) else { return }
        costs = CostHistory(days: parsed)
        try? FileManager.default.createDirectory(at: UsageTools.ownCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: UsageTools.ownCacheURL, options: .atomic)
    }
}
