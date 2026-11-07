import Foundation
import Testing
@testable import ClaudeTerm

struct UsageTests {
    /// Shape captured live from Claude Code 2.1.319 (`get_usage` control response), trimmed.
    let usageLine = #"{"type":"control_response","response":{"subtype":"success","request_id":"ccterm-usage","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":null,"seven_day":{"utilization":17,"resets_at":"2026-11-12T10:59:59.842496+00:00"},"limits":[{"kind":"weekly_all","group":"weekly","percent":17,"severity":"normal","resets_at":"2026-11-12T10:59:59.842496+00:00","is_active":true}],"model_scoped":[{"display_name":"Fable","utilization":13,"resets_at":"2026-11-12T10:59:59.842639+00:00"}]}}}}"#

    @Test func claudeCodeUsageGivesWeeklyScopedAndNoFiveHourWhenNull() throws {
        let snap = try #require(ClaudeUsageParser.parse(line: Data(usageLine.utf8), requestId: "ccterm-usage"))
        #expect(snap.fiveHour == nil)
        let weekly = try #require(snap.weekly)
        #expect(weekly.usedPercent == 17 && weekly.windowMinutes == 10080)
        let reset = try #require(weekly.resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_794_481_199.842496) < 0.001)
        #expect(snap.scoped == [ScopedQuota(name: "Fable", window: QuotaWindow(usedPercent: 13, windowMinutes: 10080,
                                                                                resetsAt: snap.scoped.first?.window.resetsAt))])
        // A response to another request id, or a system line, is not ours.
        #expect(ClaudeUsageParser.parse(line: Data(usageLine.utf8), requestId: "other") == nil)
        #expect(ClaudeUsageParser.parse(line: Data(#"{"type":"system","subtype":"init"}"#.utf8), requestId: "ccterm-usage") == nil)
    }

    @Test func fiveHourComesFromTheSessionRowWhenTheLegacyFieldIsMissing() throws {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"r","response":{"rate_limits":{"limits":[{"kind":"session","percent":42,"resets_at":"2026-11-07T12:00:00Z"}]}}}}"#
        let snap = try #require(ClaudeUsageParser.parse(line: Data(line.utf8), requestId: "r"))
        #expect(snap.fiveHour?.usedPercent == 42 && snap.fiveHour?.windowMinutes == 300)
        #expect(snap.weekly == nil)
    }

    @Test func evenPaceIsElapsedShareOfTheWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let w = QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now.addingTimeInterval(4 * 3600))
        #expect(w.expectedPercent(now: now) == 20) // 1 of 5 hours gone
        #expect(QuotaWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil).expectedPercent(now: now) == nil)
    }

    @Test func ccusageBreakdownFillsDayDetailSortedByCost() throws {
        let json = #"{"daily":[{"date":"2026-11-07","inputTokens":9685,"outputTokens":2631338,"cacheCreationTokens":29029024,"cacheReadTokens":287865041,"totalCost":230.65,"modelsUsed":["claude-opus-5-5","claude-haiku-5-5"],"modelBreakdowns":[{"modelName":"claude-haiku-5-5","cost":0.25},{"modelName":"claude-opus-5-5","cost":126.7}]}]}"#
        let h = try #require(CostParser.ccusageHistory(Data(json.utf8)))
        #expect(h.days == ["2026-11-07": 230.65])
        let d = try #require(h.details["2026-11-07"])
        #expect(d.outputTokens == 2_631_338 && d.cacheReadTokens == 287_865_041)
        #expect(d.models.map(\.name) == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(Formatting.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(Formatting.modelName("claude-sonnet-5-5-20261001") == "Sonnet 5.5")
        #expect(Formatting.tokens(2_631_338) == "2.6M" && Formatting.tokens(950) == "950")
    }

    @Test func monthTotalCountsOnlyThisCalendarMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
        let h = CostHistory(days: ["2026-10-31": 100, "2026-11-01": 10, "2026-11-07": 2.5])
        #expect(h.monthTotal(now: now, calendar: cal) == 12.5)
        #expect(h.today(now: now, calendar: cal) == 2.5)
        let recent = h.recent(8, now: now, calendar: cal)
        #expect(recent.count == 8)
        #expect(recent.first?.day == "2026-10-31" && recent.first?.cost == 100)
        #expect(recent.last?.day == "2026-11-07")
        #expect(recent[2].cost == 0) // 2026-11-02 has no usage
    }

    @Test func costParsersReadCcusageDailyLedgerAndTodayCache() {
        let daily = #"{"daily":[{"date":"2026-11-01","totalCost":1.5,"totalTokens":9},{"date":"2026-11-02","totalCost":2}]}"#
        #expect(CostParser.ccusageDaily(Data(daily.utf8)) == ["2026-11-01": 1.5, "2026-11-02": 2])
        #expect(CostParser.ledger(Data(#"{"2026-11-01": 3.25}"#.utf8)) == ["2026-11-01": 3.25])
        #expect(CostParser.todayCost(Data(#"{"id":"x","todayCost":98.7}"#.utf8)) == 98.7)
        #expect(CostParser.ccusageDaily(Data("not json".utf8)) == nil)
    }

    @Test func safeFileRejectsFifoSymlinkAndOversizeButReadsOwnFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccterm-test/safefile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("ok.json")
        try Data(#"{"todayCost":1}"#.utf8).write(to: good)
        #expect(SafeFile.read(good) == Data(#"{"todayCost":1}"#.utf8))
        #expect(SafeFile.read(good, maxBytes: 3) == nil)
        let fifo = dir.appendingPathComponent("fifo.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(SafeFile.read(fifo) == nil) // returns instead of blocking on a FIFO
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)
        #expect(SafeFile.read(link) == nil)
        #expect(SafeFile.read(dir.appendingPathComponent("missing.json")) == nil)
    }
}

struct CostMergeTests {
    @Test func scannedDaysBeatTheLedgerAndAStaleSmallerToday() {
        let detail = DayUsage(cost: 230.65, inputTokens: 1, outputTokens: 1, cacheWriteTokens: 0, cacheReadTokens: 0, models: [])
        let scanned = CostHistory(days: ["2026-11-07": 230.65], details: ["2026-11-07": detail])
        let out = CostHistory.merging(scanned: scanned, ledger: ["2026-11-06": 50, "2026-11-07": 98.69],
                                      today: 98.69, todayKey: "2026-11-07")
        #expect(out.days["2026-11-07"] == 230.65)
        #expect(out.days["2026-11-06"] == 50)
        let grown = CostHistory.merging(scanned: scanned, ledger: [:], today: 240, todayKey: "2026-11-07")
        #expect(grown.days["2026-11-07"] == 240)
    }
}
