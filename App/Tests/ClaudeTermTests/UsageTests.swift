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

    @Test func projectionExtrapolatesCurrentRateToResetButNotTooEarly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let week = 7 * 24 * 60
        // 2 of 7 days gone at 26% used: 26 * 7 / 2 = 91% at reset.
        let w = QuotaWindow(usedPercent: 26, windowMinutes: week, resetsAt: now.addingTimeInterval(5 * 86400))
        #expect(abs((w.projectedPercent(now: now) ?? 0) - 91) < 0.001)
        // 2 hours into a week is under 5% of it: no projection yet.
        let early = QuotaWindow(usedPercent: 3, windowMinutes: week, resetsAt: now.addingTimeInterval(Double(week) * 60 - 7200))
        #expect(early.projectedPercent(now: now) == nil)
    }

    @Test func monthProjectionScalesDailyAverageToMonthLength() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let h = CostHistory(days: ["2026-10-31": 999, "2026-11-01": 60, "2026-11-10": 40])
        #expect(h.projectedMonthTotal(now: now, calendar: cal) == 300) // $100 over 10 days, 30-day month
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

    @Test func weekAndMonthTotalsFollowTheCalendar() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday
        // Sunday 8 Nov 2026: the week started Monday 2 Nov.
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!
        let h = CostHistory(days: ["2026-11-01": 50, "2026-11-02": 10, "2026-11-08": 5, "2026-10-15": 7, "2026-09-30": 1])
        #expect(h.weekTotal(now: now, calendar: cal) == 15)
        let weeks = h.weekly(2, now: now, calendar: cal)
        #expect(weeks.map(\.key) == ["2026-10-26", "2026-11-02"] && weeks.map(\.cost) == [50, 15])
        let months = h.monthly(3, now: now, calendar: cal)
        #expect(months.map(\.key) == ["2026-09", "2026-10", "2026-11"] && months.map(\.cost) == [1, 7, 65])
        #expect(months[2].tokens == nil) // no day in it has token detail
    }

    @Test func weeklyOutlookMatchesThePlanningLine() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let week = 7 * 24 * 60
        // 3 of 7 days gone (even pace 42.9%) at 30% used, reset in 4 days = 96 h = 19 whole 5-hour windows.
        let w = QuotaWindow(usedPercent: 30, windowMinutes: week, resetsAt: now.addingTimeInterval(4 * 86400))
        let o = QuotaOutlook.make(weekly: w, weeklyPerSession: 30, now: now)
        #expect(Int((o.reservePercent ?? 0).rounded()) == 13)
        #expect(o.lastsUntilReset == true && o.runsOutAt == nil)
        #expect(o.windowsLeft == 19)
        #expect(abs((o.sessionQuotasLeft ?? 0) - 70.0 / 30) < 0.001)
        #expect(o.summary() == "13% in reserve \u{00B7} Lasts until reset \u{00B7} Est. 2.3 session quotas left \u{00B7} 19 windows until reset")
        // Ahead of pace: 60% used after 3 days runs out after 5 days, one day before reset.
        let hot = QuotaOutlook.make(weekly: QuotaWindow(usedPercent: 60, windowMinutes: week,
                                                        resetsAt: now.addingTimeInterval(4 * 86400)),
                                    weeklyPerSession: nil, now: now)
        #expect(hot.lastsUntilReset == false)
        #expect(abs((hot.runsOutAt?.timeIntervalSince(now) ?? 0) - 2 * 86400) < 1)
        #expect(hot.sessionQuotasLeft == nil)
    }

    @Test func ratioLearnsOnlyInsideTheSameWindows() {
        let r5 = Date(timeIntervalSince1970: 5000), rw = Date(timeIntervalSince1970: 900_000)
        func snap(_ five: Double, _ weekly: Double, fiveReset: Date) -> QuotaSnapshot {
            QuotaSnapshot(fiveHour: QuotaWindow(usedPercent: five, windowMinutes: 300, resetsAt: fiveReset),
                          weekly: QuotaWindow(usedPercent: weekly, windowMinutes: 10080, resetsAt: rw))
        }
        var t = QuotaRatioTracker()
        t.record(snap(10, 20, fiveReset: r5))
        t.record(snap(25, 23, fiveReset: r5)) // +15 five-hour, +3 weekly
        #expect(t.weeklyPerSession == nil)     // under 20 points seen
        t.record(snap(35, 25, fiveReset: r5)) // +10, +2
        #expect(abs((t.weeklyPerSession ?? 0) - 20) < 0.001) // 5 weekly per 25 five-hour = 20% per full quota
        // A new 5-hour window resets the 5-hour figure: that drop must not count.
        t.record(snap(2, 25.5, fiveReset: r5.addingTimeInterval(18000)))
        #expect(abs((t.weeklyPerSession ?? 0) - 20) < 0.001)
    }

    @Test func ccusageSessionAndBlocksParse() throws {
        let sessions = #"{"sessions":[{"sessionId":"-Users-me-a","totalCost":2,"totalTokens":10,"lastActivity":"2026-11-08","modelsUsed":["claude-opus-5-5"]},{"sessionId":"-Users-me-Desktop-video-studio","totalCost":9,"totalTokens":99},{"sessionId":"-Users-me-a","totalCost":1,"totalTokens":1}],"totals":{}}"#
        let p = try #require(CostParser.ccusageSessions(Data(sessions.utf8)))
        #expect(p.map(\.cost) == [9, 3]) // repeated key summed into one row
        #expect(ProjectKey.displayName(p[0].key, known: ["/Users/me/Desktop/video-studio"], home: "/Users/me") == "video-studio")
        #expect(ProjectKey.displayName("-Users-me-Desktop-x-y", known: [], home: "/Users/me") == "Desktop-x-y")
        #expect(ProjectKey.encode("/Users/me/my.app_1") == "-Users-me-my-app-1")
        let blocks = #"{"blocks":[{"id":"a","startTime":"2026-11-07T01:00:00.000Z","endTime":"2026-11-07T06:00:00.000Z","isActive":false,"isGap":false,"costUSD":98.7,"totalTokens":5,"models":["claude-opus-5-5"]},{"id":"g","startTime":"2026-11-07T06:00:00.000Z","endTime":"2026-11-07T08:00:00.000Z","isGap":true},{"id":"b","startTime":"2026-11-08T01:00:00.000Z","endTime":"2026-11-08T06:00:00.000Z","isActive":true,"costUSD":12,"totalTokens":7,"models":[],"burnRate":{"costPerHour":27.7},"projection":{"totalCost":111.14,"remainingMinutes":27}}]}"#
        let b = try #require(CostParser.ccusageBlocks(Data(blocks.utf8)))
        #expect(b.count == 2 && b[0].isActive && b[0].remainingMinutes == 27 && b[1].cost == 98.7)
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
