import Foundation
import Testing
@testable import ClaudeTerm

struct UsageTests {
    @Test func codexbarPlaceholderWindowIsMissingNotZero() throws {
        let json = """
        [{"provider":"claude","usage":{"primary":{"windowMinutes":300,"usedPercent":0,"isSyntheticPlaceholder":true},
          "secondary":{"resetsAt":"2026-11-12T10:59:59Z","windowMinutes":10080,"usedPercent":13,"resetDescription":"Nov 12 at 6:59PM"},
          "updatedAt":"2026-11-07T07:20:14Z"},
          "pace":{"secondary":{"expectedUsedPercent":26,"summary":"13% in reserve"}}}]
        """
        let snap = try #require(CodexbarParser.parse(Data(json.utf8)))
        #expect(snap.fiveHour == nil)
        let weekly = try #require(snap.weekly)
        #expect(weekly.usedPercent == 13 && weekly.windowMinutes == 10080)
        #expect(weekly.expectedPercent == 26 && weekly.paceSummary == "13% in reserve")
        #expect(weekly.resetText == "Nov 12 at 6:59PM" && weekly.resetsAt != nil)
        #expect(CodexbarParser.parse(Data("{}".utf8)) == nil)
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
}
