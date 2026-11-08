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

/// The weekly quota read the way a person plans with it: how much is in reserve against an even
/// pace, whether it lasts until reset, how many 5-hour windows remain, and roughly how many full
/// 5-hour quotas the rest of the week holds.
struct QuotaOutlook: Equatable {
    /// Even-pace percent minus used percent: positive is in reserve, negative is ahead of pace.
    var reservePercent: Double?
    /// When the weekly quota runs out at the current rate; nil when it lasts until reset or the
    /// rate is not known yet.
    var runsOutAt: Date?
    /// True when the current rate ends below 100% at reset; nil while the rate is not known yet.
    var lastsUntilReset: Bool?
    /// Whole 5-hour windows left before the weekly reset.
    var windowsLeft: Int?
    /// Weekly headroom divided by the weekly share one full 5-hour quota uses.
    var sessionQuotasLeft: Double?

    static func make(weekly w: QuotaWindow, weeklyPerSession: Double?, now: Date) -> QuotaOutlook {
        var o = QuotaOutlook()
        if let e = w.expectedPercent(now: now) { o.reservePercent = e - w.usedPercent }
        if let reset = w.resetsAt {
            o.windowsLeft = max(0, Int(reset.timeIntervalSince(now) / (5 * 3600)))
            if let p = w.projectedPercent(now: now) {
                o.lastsUntilReset = p < 100
                let window = Double(w.windowMinutes) * 60
                let elapsed = window - min(window, max(0, reset.timeIntervalSince(now)))
                if p >= 100, w.usedPercent > 0, elapsed > 0 {
                    let secondsTo100 = (100 - w.usedPercent) / (w.usedPercent / elapsed)
                    o.runsOutAt = now.addingTimeInterval(max(0, secondsTo100))
                }
            }
        }
        if let per = weeklyPerSession, per > 0 { o.sessionQuotasLeft = max(0, 100 - w.usedPercent) / per }
        return o
    }

    /// "9% in reserve · Lasts until reset · Est. 2.3 session quotas left · 20 windows until reset".
    func summary(now _: Date = Date()) -> String {
        var parts: [String] = []
        if let r = reservePercent {
            let n = Int(r.rounded())
            parts.append(n >= 0 ? "\(n)% in reserve" : "\(-n)% ahead of pace")
        }
        if let out = runsOutAt {
            parts.append("Runs out \(out.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
        } else if lastsUntilReset == true {
            parts.append("Lasts until reset")
        }
        if let s = sessionQuotasLeft { parts.append(String(format: "Est. %.1f session quotas left", s)) }
        if let w = windowsLeft { parts.append("\(w) window\(w == 1 ? "" : "s") until reset") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// Learns how much of the weekly quota one 5-hour quota uses, from successive snapshots taken
/// inside the same pair of windows. Saved between launches.
struct QuotaRatioTracker: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var fiveHour: Double
        var weekly: Double
        var fiveHourReset: Date?
        var weeklyReset: Date?
    }

    var fiveHourDelta = 0.0
    var weeklyDelta = 0.0
    var last: Sample?

    mutating func record(_ q: QuotaSnapshot) {
        guard let f = q.fiveHour, let w = q.weekly else { return }
        let s = Sample(fiveHour: f.usedPercent, weekly: w.usedPercent, fiveHourReset: f.resetsAt, weeklyReset: w.resetsAt)
        if let p = last, Self.same(p.fiveHourReset, s.fiveHourReset), Self.same(p.weeklyReset, s.weeklyReset) {
            let d5 = s.fiveHour - p.fiveHour, dw = s.weekly - p.weekly
            if d5 > 0, dw >= 0 {
                fiveHourDelta += d5
                weeklyDelta += dw
            }
        }
        last = s
    }

    /// Weekly percent one full 5-hour quota uses. Nil until 20 points of 5-hour usage were seen.
    var weeklyPerSession: Double? {
        fiveHourDelta >= 20 ? weeklyDelta / fiveHourDelta * 100 : nil
    }

    private static func same(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) < 120
    }
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

/// Cost and tokens over one week or month. `tokens` is nil when no day in it has token detail.
struct PeriodUsage: Equatable {
    var key: String
    var cost: Double
    var tokens: Int?
}

/// One project's usage from `ccusage session`, which groups by project folder.
struct ProjectUsage: Equatable {
    /// Claude Code's folder key: the project path with every non-alphanumeric character as "-".
    var key: String
    var cost: Double
    var tokens: Int
    var lastActivity: String
    var models: [String]
}

/// One 5-hour billing block from `ccusage blocks`.
struct UsageBlock: Equatable {
    var start: Date
    var end: Date
    var isActive: Bool
    var cost: Double
    var tokens: Int
    var models: [String]
    var costPerHour: Double?
    var projectedCost: Double?
    var remainingMinutes: Int?
}

enum ProjectKey {
    /// How Claude Code names a project's transcript folder: "/Users/me/my.app" -> "-Users-me-my-app".
    static func encode(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The folder name of a known project with this key, else the key with the home prefix removed.
    static func displayName(_ key: String, known: [String], home: String = NSHomeDirectory()) -> String {
        if let path = known.first(where: { encode($0) == key }) { return SidebarLayout.projectName(path) }
        let homeKey = encode(home) + "-"
        return key.hasPrefix(homeKey) ? String(key.dropFirst(homeKey.count)) : key
    }
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

    /// From the first day of this week (the locale's first weekday) through today.
    func weekTotal(now: Date, calendar: Calendar = .current) -> Double {
        weekly(1, now: now, calendar: calendar).first?.cost ?? 0
    }

    /// The last `count` calendar weeks ending with this one, oldest first. Key: the week's first day.
    func weekly(_ count: Int, now: Date, calendar: Calendar = .current) -> [PeriodUsage] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (0..<count).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek) else { return nil }
            let keys = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
                .map { Self.dayKey($0, calendar: calendar) }
            return period(Self.dayKey(start, calendar: calendar), keys)
        }
    }

    /// The last `count` calendar months ending with this one, oldest first. Key: "yyyy-MM".
    func monthly(_ count: Int, now: Date, calendar: Calendar = .current) -> [PeriodUsage] {
        (0..<count).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .month, value: -back, to: now) else { return nil }
            let prefix = String(Self.dayKey(d, calendar: calendar).prefix(8))
            let keys = Set(days.keys).union(details.keys).filter { $0.hasPrefix(prefix) }
            return period(String(prefix.dropLast()), Array(keys))
        }
    }

    private func period(_ key: String, _ dayKeys: [String]) -> PeriodUsage {
        let cost = dayKeys.reduce(0) { $0 + (days[$1] ?? 0) }
        let detailed = dayKeys.compactMap { details[$0] }
        let tokens = detailed.isEmpty ? nil
            : detailed.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheWriteTokens + $1.cacheReadTokens }
        return PeriodUsage(key: key, cost: cost, tokens: tokens)
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

    /// `ccusage session --json`: {"sessions": [{"sessionId": "-Users-me-app", "totalCost": 1.2, ...}]}.
    /// Sorted by cost, highest first.
    static func ccusageSessions(_ data: Data) -> [ProjectUsage]? {
        struct Out: Decodable {
            struct S: Decodable {
                var sessionId: String
                var totalCost: Double
                var totalTokens: Int?
                var lastActivity: String?
                var modelsUsed: [String]?
            }

            var sessions: [S]
        }
        guard let out = try? JSONDecoder().decode(Out.self, from: data) else { return nil }
        // One row per key: the list ids must be unique, so repeated keys are summed.
        var byKey: [String: ProjectUsage] = [:]
        for s in out.sessions {
            var p = byKey[s.sessionId] ?? ProjectUsage(key: s.sessionId, cost: 0, tokens: 0, lastActivity: "", models: [])
            p.cost += s.totalCost
            p.tokens += s.totalTokens ?? 0
            p.lastActivity = max(p.lastActivity, s.lastActivity ?? "")
            p.models = Array(Set(p.models + (s.modelsUsed ?? []))).sorted()
            byKey[s.sessionId] = p
        }
        return byKey.values.sorted { $0.cost == $1.cost ? $0.key < $1.key : $0.cost > $1.cost }
    }

    /// `ccusage blocks --json`: {"blocks": [...]}. Gap blocks are dropped; newest first.
    static func ccusageBlocks(_ data: Data) -> [UsageBlock]? {
        struct Out: Decodable {
            struct B: Decodable {
                struct Burn: Decodable { var costPerHour: Double? }
                struct Projection: Decodable {
                    var totalCost: Double?
                    var remainingMinutes: Int?
                }

                var startTime: String
                var endTime: String
                var isActive: Bool?
                var isGap: Bool?
                var costUSD: Double?
                var totalTokens: Int?
                var models: [String]?
                var burnRate: Burn?
                var projection: Projection?
            }

            var blocks: [B]
        }
        guard let out = try? JSONDecoder().decode(Out.self, from: data) else { return nil }
        return out.blocks.compactMap { b -> UsageBlock? in
            guard b.isGap != true, let start = ClaudeUsageParser.date(b.startTime),
                  let end = ClaudeUsageParser.date(b.endTime) else { return nil }
            return UsageBlock(start: start, end: end, isActive: b.isActive ?? false, cost: b.costUSD ?? 0,
                              tokens: b.totalTokens ?? 0, models: (b.models ?? []).filter { $0 != "<synthetic>" },
                              costPerHour: b.burnRate?.costPerHour, projectedCost: b.projection?.totalCost,
                              remainingMinutes: b.projection?.remainingMinutes)
        }
        .sorted { $0.start > $1.start }
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
    static var ownCacheURL: URL { cacheURL("ccusage-daily.json") }
    static var sessionCacheURL: URL { cacheURL("ccusage-session.json") }
    static var blocksCacheURL: URL { cacheURL("ccusage-blocks.json") }

    private static func cacheURL(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeTerm/" + name)
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var quota: QuotaSnapshot?
    @Published private(set) var costs: CostHistory?
    @Published private(set) var quotaUnavailable = false
    @Published private(set) var costMissingTool = false
    @Published private(set) var costIsRefreshing = false
    /// Per-project cost over the last 30 days (`ccusage session`), highest first.
    @Published private(set) var projects: [ProjectUsage] = []
    /// 5-hour blocks over the last 7 days (`ccusage blocks`), newest first.
    @Published private(set) var blocks: [UsageBlock] = []
    @Published private(set) var ratio: QuotaRatioTracker

    private let claudePath: @Sendable () -> String?
    private let defaults: UserDefaults?
    private var task: Task<Void, Never>?
    private var lastCostScan: Date?
    private var lastBreakdownScan: Date?
    static let ratioKey = "usage.quotaRatio"

    init(claudePath: @escaping @Sendable () -> String? = { nil }, defaults: UserDefaults? = nil) {
        self.claudePath = claudePath
        self.defaults = defaults
        ratio = defaults?.data(forKey: Self.ratioKey)
            .flatMap { try? JSONDecoder().decode(QuotaRatioTracker.self, from: $0) } ?? QuotaRatioTracker()
    }

    var outlook: QuotaOutlook? {
        guard let w = quota?.weekly else { return nil }
        return QuotaOutlook.make(weekly: w, weeklyPerSession: ratio.weeklyPerSession, now: Date())
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
            ratio.record(snap)
            if let data = try? JSONEncoder().encode(ratio) { defaults?.set(data, forKey: Self.ratioKey) }
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
        if projects.isEmpty, let data = SafeFile.read(UsageTools.sessionCacheURL),
           let cached = CostParser.ccusageSessions(data) { projects = cached }
        if blocks.isEmpty, let data = SafeFile.read(UsageTools.blocksCacheURL),
           let cached = CostParser.ccusageBlocks(data) { blocks = cached }
        if let last = lastCostScan, Date().timeIntervalSince(last) < 30 * 60 { return }
        guard let tool = UsageTools.find("ccusage", override: "CCTERM_CCUSAGE_PATH") else {
            costMissingTool = costs == nil
            return
        }
        lastCostScan = Date()
        costIsRefreshing = true
        defer { costIsRefreshing = false }
        // Three calendar months, for the Monthly view; the Daily view shows the last 30 days of it.
        let cal = Calendar.current
        let monthStart = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        let since = Self.sinceArg(cal.date(byAdding: .month, value: -2, to: monthStart) ?? monthStart)
        if let data = await Self.ccusage(tool, ["daily", "--json", "--breakdown", "--since", since]),
           let parsed = CostParser.ccusageHistory(data) {
            var merged = parsed
            merged.days.merge(history.days) { scanned, _ in scanned }
            merged.details.merge(history.details) { scanned, _ in scanned }
            costs = merged
            Self.save(data, UsageTools.ownCacheURL)
        }
        // Each ccusage scan takes minutes: the project and block views refresh hourly.
        // The timestamp is set only after both scans succeed, so a failed scan retries on the next cycle.
        if let last = lastBreakdownScan, Date().timeIntervalSince(last) < 60 * 60 { return }
        var ok = true
        let month = Self.sinceArg(cal.date(byAdding: .day, value: -29, to: Date()) ?? Date())
        if let data = await Self.ccusage(tool, ["session", "--json", "--since", month]),
           let parsed = CostParser.ccusageSessions(data) {
            projects = parsed
            Self.save(data, UsageTools.sessionCacheURL)
        } else { ok = false }
        let week = Self.sinceArg(cal.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        if let data = await Self.ccusage(tool, ["blocks", "--json", "--since", week]),
           let parsed = CostParser.ccusageBlocks(data) {
            blocks = parsed
            Self.save(data, UsageTools.blocksCacheURL)
        } else { ok = false }
        if ok { lastBreakdownScan = Date() }
    }

    /// ccusage is a bun/node script: run it through env so its interpreter is found on the search path.
    private static func ccusage(_ tool: String, _ args: [String]) async -> Data? {
        await ProcessRunner.run("/usr/bin/env", ["PATH=\(UsageTools.searchPath)", tool] + args, timeout: 600)
    }

    private static func sinceArg(_ d: Date) -> String {
        CostHistory.dayKey(d).replacingOccurrences(of: "-", with: "")
    }

    private static func save(_ data: Data, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
