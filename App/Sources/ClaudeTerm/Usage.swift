import Darwin
import Foundation

// Usage data. Plan quota comes from Claude Code itself (the SDK `get_usage` control request, which
// sends no prompt and costs nothing). Daily API-equivalent cost comes from `ccusage`, which reads
// Claude Code's own transcripts. The app never talks to an Anthropic API directly.

struct QuotaWindow: Equatable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?

    /// Where usage would be now if spread evenly over the window; nil without a reset time.
    func expectedPercent(now: Date) -> Double? {
        guard let resetsAt, windowMinutes > 0 else { return nil }
        let window = Double(windowMinutes) * 60
        let left = min(window, max(0, resetsAt.timeIntervalSince(now)))
        return (window - left) / window * 100
    }

    /// Usage at reset if the current rate holds. Nil until 5% of the window (at least an hour) has
    /// passed, because an early extrapolation swings wildly.
    func projectedPercent(now: Date) -> Double? {
        guard let resetsAt, windowMinutes > 0 else { return nil }
        let window = Double(windowMinutes) * 60
        let elapsed = window - min(window, max(0, resetsAt.timeIntervalSince(now)))
        guard elapsed >= max(3600, window * 0.05) else { return nil }
        return usedPercent * window / elapsed
    }
}

struct ScopedQuota: Equatable {
    var name: String
    var window: QuotaWindow
}

struct QuotaSnapshot: Equatable {
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    var scoped: [ScopedQuota] = []
    var updatedAt: Date?
}

enum ClaudeUsageParser {
    private struct Line: Decodable {
        var type: String
        var response: Outer?
    }

    private struct Outer: Decodable {
        var subtype: String
        var request_id: String?
        var response: Body?
    }

    private struct Body: Decodable {
        var rate_limits_available: Bool?
        var rate_limits: Limits?
    }

    private struct Limits: Decodable {
        var five_hour: Window?
        var seven_day: Window?
        var model_scoped: [Scoped]?
        var limits: [Row]?
    }

    private struct Window: Decodable {
        var utilization: Double?
        var resets_at: String?
    }

    private struct Scoped: Decodable {
        var display_name: String?
        var utilization: Double?
        var resets_at: String?
    }

    private struct Row: Decodable {
        var kind: String?
        var percent: Double?
        var resets_at: String?
    }

    /// One stdout line of `claude -p --output-format stream-json`. Returns nil unless it is the
    /// successful control response to `requestId`.
    static func parse(line: Data, requestId: String, now: Date = Date()) -> QuotaSnapshot? {
        guard let l = try? JSONDecoder().decode(Line.self, from: line), l.type == "control_response",
              let outer = l.response, outer.subtype == "success", outer.request_id == requestId,
              let body = outer.response else { return nil }
        guard body.rate_limits_available != false, let r = body.rate_limits else {
            return QuotaSnapshot(updatedAt: now)
        }
        func window(_ w: Window?, minutes: Int) -> QuotaWindow? {
            guard let used = w?.utilization else { return nil }
            return QuotaWindow(usedPercent: used, windowMinutes: minutes, resetsAt: w?.resets_at.flatMap(date))
        }
        // The server's `limits[]` rows are authoritative when the legacy fields are missing.
        func row(_ kind: String, minutes: Int) -> QuotaWindow? {
            guard let row = r.limits?.first(where: { $0.kind == kind }), let p = row.percent else { return nil }
            return QuotaWindow(usedPercent: p, windowMinutes: minutes, resetsAt: row.resets_at.flatMap(date))
        }
        let scoped = (r.model_scoped ?? []).compactMap { s -> ScopedQuota? in
            guard let name = s.display_name, let used = s.utilization else { return nil }
            return ScopedQuota(name: name, window: QuotaWindow(usedPercent: used, windowMinutes: 7 * 24 * 60,
                                                               resetsAt: s.resets_at.flatMap(date)))
        }
        return QuotaSnapshot(fiveHour: window(r.five_hour, minutes: 300) ?? row("session", minutes: 300),
                             weekly: window(r.seven_day, minutes: 7 * 24 * 60) ?? row("weekly_all", minutes: 7 * 24 * 60),
                             scoped: scoped, updatedAt: now)
    }

    /// ISO 8601 with any number of fractional digits ("2026-11-12T10:59:59.842496+00:00").
    static func date(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let rest = s[s.index(after: dot)...]
        let digits = rest.prefix { $0.isNumber }
        let zone = rest.dropFirst(digits.count)
        guard let whole = plain.date(from: String(s[..<dot]) + zone) else { return nil }
        let frac = Double("0." + digits) ?? 0
        return whole.addingTimeInterval(frac)
    }
}

/// Runs Claude Code in print mode with stream-json I/O, sends the `get_usage` control request and
/// returns the first matching response. No user message is sent, so no model call is made.
enum ClaudeUsageProbe {
    static let requestId = "ccterm-usage"

    static func fetch(claude: String, timeout: TimeInterval = 40) async -> QuotaSnapshot? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeTerm-usage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return await withCheckedContinuation { (cont: CheckedContinuation<QuotaSnapshot?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                // Process is not Sendable; it is created here and only touched by this block and the
                // timeout item, which only terminates our own child.
                nonisolated(unsafe) let proc = Process()
                proc.executableURL = URL(fileURLWithPath: claude)
                proc.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                  "--verbose", "--no-session-persistence"]
                proc.currentDirectoryURL = dir
                let input = Pipe(), output = Pipe()
                proc.standardInput = input
                proc.standardOutput = output
                proc.standardError = FileHandle.nullDevice
                do { try proc.run() } catch {
                    cont.resume(returning: nil)
                    return
                }
                let pid = proc.processIdentifier
                let killer = DispatchWorkItem {
                    guard proc.isRunning else { return }
                    proc.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if proc.isRunning { kill(pid, SIGKILL) } }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let request = #"{"type":"control_request","request_id":"\#(requestId)","request":{"subtype":"get_usage"}}"# + "\n"
                input.fileHandleForWriting.write(Data(request.utf8))
                var buffer = Data()
                var result: QuotaSnapshot?
                let reader = output.fileHandleForReading
                while result == nil {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<nl]
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if let snap = ClaudeUsageParser.parse(line: Data(line), requestId: requestId) {
                            result = snap
                            break
                        }
                    }
                    if buffer.count > 4 * 1024 * 1024 { break }
                }
                try? input.fileHandleForWriting.close()
                killer.cancel()
                if proc.isRunning {
                    proc.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if proc.isRunning { kill(pid, SIGKILL) } }
                }
                cont.resume(returning: result)
            }
        }
    }
}

/// One day of ccusage data, for the bar hover card.
struct DayUsage: Equatable {
    struct Model: Equatable {
        var name: String
        var cost: Double
    }

    var cost: Double
    var inputTokens: Int
    var outputTokens: Int
    var cacheWriteTokens: Int
    var cacheReadTokens: Int
    var models: [Model]
}

/// Daily API-equivalent cost in USD, keyed by local date "yyyy-MM-dd".
struct CostHistory: Equatable {
    var days: [String: Double]
    /// Token and model detail per day, when ccusage has been run with --breakdown.
    var details: [String: DayUsage] = [:]

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A day ccusage scanned in full (it has detail) keeps its scanned cost. The ledger fills the
    /// other days; a fresh today value applies only when today has no scan or the value is larger
    /// (cost within a day only grows, so a larger fresh number is newer).
    static func merging(scanned: CostHistory, ledger: [String: Double], today: Double?, todayKey: String) -> CostHistory {
        var out = scanned
        for (day, cost) in ledger where out.details[day] == nil { out.days[day] = cost }
        if let today, today > (out.days[todayKey] ?? 0) { out.days[todayKey] = today }
        return out
    }

    func monthTotal(now: Date, calendar: Calendar = .current) -> Double {
        let prefix = String(Self.dayKey(now, calendar: calendar).prefix(8)) // "yyyy-MM-"
        return days.filter { $0.key.hasPrefix(prefix) }.reduce(0) { $0 + $1.value }
    }

    /// Month total at month end if the daily average so far holds.
    func projectedMonthTotal(now: Date, calendar: Calendar = .current) -> Double {
        let day = calendar.component(.day, from: now)
        let length = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        return monthTotal(now: now, calendar: calendar) / Double(max(1, day)) * Double(length)
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
    private struct Out: Decodable {
        struct Breakdown: Decodable {
            var modelName: String
            var cost: Double
        }

        struct Day: Decodable {
            var date: String
            var totalCost: Double
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheCreationTokens: Int?
            var cacheReadTokens: Int?
            var modelsUsed: [String]?
            var modelBreakdowns: [Breakdown]?
        }

        var daily: [Day]
    }

    /// `ccusage daily --json [--breakdown]`: {"daily": [{"date": "2026-11-01", "totalCost": 12.3, ...}]}.
    static func ccusageDaily(_ data: Data) -> [String: Double]? {
        ccusageHistory(data)?.days
    }

    static func ccusageHistory(_ data: Data) -> CostHistory? {
        guard let out = try? JSONDecoder().decode(Out.self, from: data) else { return nil }
        var history = CostHistory(days: Dictionary(out.daily.map { ($0.date, $0.totalCost) }, uniquingKeysWith: +))
        for d in out.daily where d.inputTokens != nil {
            let models = (d.modelBreakdowns ?? []).map { DayUsage.Model(name: $0.modelName, cost: $0.cost) }
                .sorted { $0.cost > $1.cost }
            history.details[d.date] = DayUsage(
                cost: d.totalCost, inputTokens: d.inputTokens ?? 0, outputTokens: d.outputTokens ?? 0,
                cacheWriteTokens: d.cacheCreationTokens ?? 0, cacheReadTokens: d.cacheReadTokens ?? 0,
                models: models.isEmpty ? (d.modelsUsed ?? []).map { DayUsage.Model(name: $0, cost: 0) } : models)
        }
        return history
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
    @Published private(set) var quotaUnavailable = false
    @Published private(set) var costMissingTool = false
    @Published private(set) var costIsRefreshing = false

    private let claudePath: @Sendable () -> String?
    private var task: Task<Void, Never>?
    private var lastCostScan: Date?

    init(claudePath: @escaping @Sendable () -> String? = { nil }) {
        self.claudePath = claudePath
    }

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
        guard let claude = claudePath() else {
            quotaUnavailable = true
            return
        }
        if let snap = await ClaudeUsageProbe.fetch(claude: claude) {
            quota = snap
            quotaUnavailable = false
        } else if quota == nil {
            quotaUnavailable = true
        }
    }

    /// Daily totals come first from a ledger a ccusage status line already keeps (instant). The
    /// per-day token and model detail needs `ccusage daily --breakdown`, run at most every 30 minutes
    /// and cached, because one scan takes minutes.
    /// The status line's today cache, only while it is fresh: it is rewritten only while a status
    /// line runs, and a stale value was seen overriding a newer scan (2026-11-07: $98.69 vs $230.65).
    private static func freshTodayCost(maxAge: TimeInterval = 600) -> Double? {
        let url = UsageTools.todayCacheURL
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < maxAge,
              let data = SafeFile.read(url) else { return nil }
        return CostParser.todayCost(data)
    }

    private func refreshCosts() async {
        var history = CostHistory(days: [:])
        if let data = SafeFile.read(UsageTools.ownCacheURL), let cached = CostParser.ccusageHistory(data) {
            history = cached
        }
        if let data = SafeFile.read(UsageTools.ledgerURL), let ledger = CostParser.ledger(data) {
            history = CostHistory.merging(scanned: history, ledger: ledger,
                                          today: Self.freshTodayCost(), todayKey: CostHistory.dayKey(Date()))
        }
        if !history.days.isEmpty { costs = history }
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
        guard let data = await ProcessRunner.run("/usr/bin/env",
                                                 ["PATH=\(UsageTools.searchPath)", tool, "daily", "--json", "--breakdown", "--since", since],
                                                 timeout: 600),
              let parsed = CostParser.ccusageHistory(data) else { return }
        var merged = parsed
        merged.days.merge(history.days) { scanned, _ in scanned }
        merged.details.merge(history.details) { scanned, _ in scanned }
        costs = merged
        try? FileManager.default.createDirectory(at: UsageTools.ownCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: UsageTools.ownCacheURL, options: .atomic)
    }
}
