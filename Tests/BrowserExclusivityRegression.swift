import Cocoa

@main
struct BrowserExclusivityRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoyuBrowserExclusivity-\(UUID())")
        setenv("MOYU_DB_DIR", directory.path, 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store()
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "PASS" : "FAIL") \(description)")
            if !condition { failures += 1 }
        }
        let start = DayRange.localCalendar.startOfDay(for: Date()).addingTimeInterval(60)
        var now = start
        let browserIDs = Set(WebGroup.browsers.keys).union(["com.qihoo.litebrowserx"]).sorted()
        for (index, bundle) in browserIDs.enumerated() {
            let raw = store.openSession(bundleId: bundle, name: bundle, start: now)
            store.setCategory(appId: raw.appId, category: [.work, .slack, .ignored][index % 3])
            now.addTimeInterval(1)
            store.closeSession(rowId: raw.rowId, endTs: Int(now.timeIntervalSince1970))
        }
        func record(_ bundle: String, seconds: Int, domain: String? = nil) {
            let session = store.openSession(bundleId: bundle, name: bundle, domain: domain, start: now)
            now.addTimeInterval(Double(seconds))
            store.closeSession(rowId: session.rowId, endTs: Int(now.timeIntervalSince1970))
        }
        record(WebGroup.bundleId, seconds: 5, domain: "github.com")
        store.setDomainCategory(domain: "github.com", category: .work)
        record(WebGroup.bundleId, seconds: 3, domain: "bilibili.com")
        store.setDomainCategory(domain: "bilibili.com", category: .slack)
        record(WebGroup.bundleId, seconds: 2, domain: "ignored.example.com")
        store.setDomainCategory(domain: "ignored.example.com", category: .ignored)
        record("com.apple.Terminal", seconds: 7)
        store.setCategory(appId: store.appId(bundleId: "com.apple.Terminal")!, category: .work)
        let expected: [AppCategory: Int] = [.work: 12_000, .slack: 3_000, .ignored: 2_000]
        let ranges = [("day", DayRange.day(start)), ("week", DayRange.week(start)), ("month", DayRange.month(start))]
        for (label, range) in ranges {
            let rows = store.appUsage(from: range.start, to: range.end)
            check(rows.allSatisfy { !browserIDs.contains($0.bundleId) }, "\(label): no recognized browser is listed as a native app")
            check(store.categoryTotals(from: range.start, to: range.end) == expected,
                  "\(label): browser-native history is excluded from every category total")
            let daily = store.dailyBreakdown(from: range.start, to: range.end)
                .reduce(into: [AppCategory: Int]()) { $0[$1.category, default: 0] += $1.ms }
            check(daily == expected, "\(label): trend and heatmap totals match website-only browser counting")
        }
        let day = DayRange.day(start)
        let webID = store.appId(bundleId: WebGroup.bundleId)!
        check(store.domainUsage(appId: webID, from: day.start, to: day.end).reduce(0) { $0 + $1.ms } == 10_000,
              "excluding browser-app records preserves all attributed website time")
        for bundle in browserIDs {
            let tracker = UsageTracker(store: store)
            tracker.nowProvider = { now }
            tracker.idleProvider = { 0 }
            tracker.passiveSignalProvider = { _, _ in false }
            tracker.frontmostProvider = { (bundle, bundle) }
            tracker.domainProvider = { _, reply in reply(.failed) }
            tracker.tick()
            now.addTimeInterval(1)
            check(tracker.liveSession == nil && tracker.liveDelta() == nil,
                  "\(bundle): a failed URL read never falls back to native or live time")
            tracker.shutdown()
        }
        check(WebGroup.isBrowser("com.qihoo.litebrowserx") && WebGroup.appleScriptAppName("com.qihoo.litebrowserx") == nil,
              "360 Store edition is a recognized browser without claiming URL or automation support")
        let reopened = try Store()
        check(reopened.categoryTotals(from: day.start, to: day.end) == expected,
              "restarting cannot restore excluded browser-native totals")
        let qqID = reopened.appId(bundleId: "com.tencent.qqbrowserappmac")!
        check(!reopened.sessions(appId: qqID, from: day.start, to: day.end).isEmpty,
              "excluded browser-native records remain available in raw storage")
        if failures > 0 { exit(1) }
    }
}
