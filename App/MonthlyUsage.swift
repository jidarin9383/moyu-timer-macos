import Foundation

/// Calendar-day totals for the month overview. Future dates and ignored usage are excluded.
struct MonthlyUsage {
    struct Day: Identifiable, Equatable {
        let start: Int
        let workMs: Int
        let slackMs: Int
        var id: Int { start }
        var date: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
        var totalMs: Int { workMs + slackMs }
        var slackRate: Double { totalMs > 0 ? Double(slackMs) / Double(totalMs) : 0 }
    }

    let days: [Day]

    init(from: Int, to: Int, daily: [DayCategoryUsage], live: StatsViewModel.LiveInfo?, now: Date = Date()) {
        let today = DayRange.day(now).start
        var totals: [Int: (work: Int, slack: Int)] = [:]
        for row in daily where row.dayStart >= from && row.dayStart < to && row.dayStart <= today {
            if row.category == .work { totals[row.dayStart, default: (0, 0)].work += row.ms }
            if row.category == .slack { totals[row.dayStart, default: (0, 0)].slack += row.ms }
        }
        if let live, today >= from, today < to {
            if live.category == .work { totals[today, default: (0, 0)].work += live.ms }
            if live.category == .slack { totals[today, default: (0, 0)].slack += live.ms }
        }
        var result: [Day] = []
        var cursor = from
        while cursor < to && cursor <= today {
            let total = totals[cursor] ?? (0, 0)
            result.append(Day(start: cursor, workMs: total.work, slackMs: total.slack))
            let next = DayRange.nextLocalMidnight(after: cursor)
            guard next > cursor else { break }
            cursor = next
        }
        days = result
    }

    var recordedDays: Int { days.filter { $0.totalMs > 0 }.count }
    var totalMs: Int { days.reduce(0) { $0 + $1.totalMs } }
    var averageMs: Int { recordedDays > 0 ? totalMs / recordedDays : 0 }
    var latestRecordedDay: Day? { days.last { $0.totalMs > 0 } }

    func day(containing date: Date) -> Day? {
        let start = DayRange.day(date).start
        return days.first { $0.start == start }
    }
}
