import Foundation

@main
struct MonthlyUsageRegression {
    static func main() {
        let calendar = DayRange.localCalendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
        let range = DayRange.month(now)
        func day(_ value: Int) -> Int {
            Int(calendar.date(from: DateComponents(year: 2026, month: 10, day: value))!.timeIntervalSince1970)
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        let rows = [
            DayCategoryUsage(dayStart: day(1), category: .work, ms: 30_000),
            DayCategoryUsage(dayStart: day(1), category: .work, ms: 30_000),
            DayCategoryUsage(dayStart: day(1), category: .slack, ms: 60_000),
            DayCategoryUsage(dayStart: day(3), category: .ignored, ms: 500_000),
            DayCategoryUsage(dayStart: day(17), category: .work, ms: 60_000),
            DayCategoryUsage(dayStart: day(18), category: .work, ms: 999_000)
        ]
        let live = StatsViewModel.LiveInfo(ms: 60_000, category: .slack, appId: 1)
        let usage = MonthlyUsage(from: range.start, to: range.end, daily: rows, live: live, now: now)
        check(usage.days.count == 17, "current month stops at today")
        check(usage.totalMs == 240_000, "monthly bars include live usage and exclude ignored/future usage")
        check(usage.recordedDays == 2 && usage.averageMs == 120_000,
              "daily average uses dates with counted records")
        let first = usage.day(containing: Date(timeIntervalSince1970: TimeInterval(day(1) + 3600)))
        check(first?.workMs == 60_000 && first?.slackMs == 60_000, "same-day category rows aggregate correctly")
        check(first?.slackRate == 0.5, "inline day summary uses work plus leisure as its denominator")
        check(usage.day(containing: Date(timeIntervalSince1970: TimeInterval(day(2))))?.totalMs == 0,
              "past days without records remain selectable as zero")
        check(usage.day(containing: Date(timeIntervalSince1970: TimeInterval(day(18)))) == nil,
              "future dates cannot become selected days")
        check(usage.latestRecordedDay?.start == day(17), "initial day summary selects latest counted date")
        let previousRange = DayRange.month(calendar.date(byAdding: .month, value: -1, to: now)!)
        let previous = MonthlyUsage(from: previousRange.start, to: previousRange.end, daily: rows, live: live, now: now)
        check(previous.days.count == 30 && previous.totalMs == 0, "historical month excludes current live usage")
        check(previous.averageMs == 0 && previous.latestRecordedDay == nil, "empty months have a safe zero average")
        let leapRange = DayRange.month(calendar.date(from: DateComponents(year: 2024, month: 2, day: 1))!)
        let leap = MonthlyUsage(from: leapRange.start, to: leapRange.end, daily: [], live: nil, now: now)
        check(leap.days.count == 29, "monthly chart respects leap-year calendar boundaries")
        let ignoredLive = MonthlyUsage(from: range.start, to: range.end, daily: rows,
            live: StatsViewModel.LiveInfo(ms: 999_000, category: .ignored, appId: 1), now: now)
        check(ignoredLive.totalMs == 180_000, "ignored live usage never enters monthly totals")
        if failures > 0 { exit(1) }
    }
}
