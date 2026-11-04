import Cocoa
import Combine

@main
struct InteractionRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoyuInteraction-\(UUID())")
        setenv("MOYU_DB_DIR", root.path, 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store()
        let base = Date()
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let session = store.openSession(bundleId: "com.apple.dt.Xcode", name: "Xcode", start: base)
        store.closeSession(rowId: session.rowId, endTs: Int(base.timeIntervalSince1970) + 10)
        let range = DayRange.day(base)
        check(store.appUsage(from: range.start, to: range.end).map(\.id)
              == store.appUsage(from: range.start, to: range.end).map(\.id),
              "app identity survives snapshot refresh")
        check(store.dailyBreakdown(from: range.start, to: range.end).map(\.id)
              == store.dailyBreakdown(from: range.start, to: range.end).map(\.id),
              "chart identity survives snapshot refresh")
        let web = store.openSession(bundleId: WebGroup.bundleId, name: WebGroup.name,
                                    domain: "github.com", start: base)
        store.closeSession(rowId: web.rowId, endTs: Int(base.timeIntervalSince1970) + 10)
        check(store.domainUsage(appId: web.appId, from: range.start, to: range.end).map(\.id)
              == store.domainUsage(appId: web.appId, from: range.start, to: range.end).map(\.id),
              "domain identity survives view refresh")
        let tracker = UsageTracker(store: store)
        tracker.passiveSignalProvider = { _, _ in false }
        var now = base
        var requests = 0
        tracker.nowProvider = { now }
        tracker.idleProvider = { 0 }
        tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
        tracker.domainProvider = { _, completion in requests += 1; completion(.failed) }
        for offset in 0..<5 {
            now = base.addingTimeInterval(Double(offset))
            tracker.tick()
        }
        check(requests == 1, "failed URL queries respect five-second retry interval")
        check(tracker.liveSession == nil, "failed URL reads do not count browser time")
        now = base.addingTimeInterval(5)
        tracker.tick()
        check(requests == 2, "failed URL query retries after five seconds")

        var front = "com.google.Chrome"
        tracker.frontmostProvider = { (front, "Test") }
        tracker.tick()
        front = "com.example.popover"
        tracker.tick()
        tracker.runningBrowsersProvider = { ["com.apple.Safari", "com.google.Chrome"] }
        var authorizationTarget: String?
        var authorizationCompletion: ((BrowserPermissionResult) -> Void)?
        var settingsOpened = 0
        tracker.openAutomationSettingsProvider = { settingsOpened += 1 }
        tracker.authorizationProvider = { target, completion in
            authorizationTarget = target
            authorizationCompletion = completion
        }
        tracker.goAuthorize()
        check(authorizationTarget == "com.google.Chrome", "authorize remembered browser from our own UI")
        check(UserDefaults.standard.bool(forKey: UsageTracker.webRetryPendingKey), "authorization shows pending state")
        authorizationTarget = nil
        tracker.goAuthorize()
        check(authorizationTarget == nil, "repeated authorization clicks do not duplicate prompts")
        authorizationCompletion?(.denied)
        check(settingsOpened == 1, "denied permission opens Automation settings")
        check(!UserDefaults.standard.bool(forKey: UsageTracker.webRetryPendingKey), "denied permission clears pending state")
        tracker.goAuthorize()
        authorizationCompletion?(.authorized)
        check(!UserDefaults.standard.bool(forKey: BrowserURLReader.permissionDeniedKey), "successful consent clears denied state")
        check(settingsOpened == 1, "successful consent does not open settings")
        authorizationTarget = nil
        tracker.goAuthorize(bundleId: "com.apple.Safari")
        check(authorizationTarget == "com.apple.Safari", "settings authorize the selected running browser")
        authorizationCompletion?(.authorized)
        tracker.runningBrowsersProvider = { ["com.google.Chrome"] }
        authorizationTarget = nil
        tracker.goAuthorize(bundleId: "com.apple.Safari")
        check(authorizationTarget == nil, "closed selected browser does not authorize a different browser")
        check((UserDefaults.standard.string(forKey: UsageTracker.webPermissionMessageKey) ?? "").contains("Safari"),
              "closed selected browser shows its name in the guidance")
        tracker.runningBrowsersProvider = { ["com.apple.Safari", "com.google.Chrome"] }
        front = "com.google.Chrome"
        tracker.domainProvider = { _, completion in completion(.domain("github.com")) }
        tracker.tick()
        check(tracker.liveSession?.domain == "github.com", "URL monitoring resumes after authorization")
        now = now.addingTimeInterval(1)
        let vm = StatsViewModel(store: store, tracker: tracker)
        check(vm.live != nil, "current period shows live usage")
        vm.previous()
        check(vm.liveForCurrentRange == nil, "historical period excludes live usage")
        vm.backToToday()
        tracker.suspendForOwnUI()
        vm.rebuildSnapshots()
        var publications = 0
        let subscription = vm.objectWillChange.sink { publications += 1 }
        vm.startUpdates()
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
        vm.stopUpdates()
        check(publications == 0, "unchanged visible statistics do not republish while scrolling")
        withExtendedLifetime(subscription) {}
        let calendar = DayRange.localCalendar
        let beforeMidnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18,
                                                                 hour: 23, minute: 59, second: 59))!
        var displayNow = beforeMidnight
        let rolloverVM = StatsViewModel(store: store, tracker: tracker, nowProvider: { displayNow })
        rolloverVM.startUpdates()
        displayNow = beforeMidnight.addingTimeInterval(2)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        rolloverVM.stopUpdates()
        check(rolloverVM.day.rangeStart == DayRange.day(displayNow).start,
              "visible statistics follow today across midnight")
        displayNow = calendar.date(byAdding: .day, value: 3, to: displayNow)!
        rolloverVM.startUpdates()
        rolloverVM.stopUpdates()
        check(rolloverVM.day.rangeStart == DayRange.day(displayNow).start,
              "reopening statistics after several days immediately follows today")
        rolloverVM.previous()
        let historicalStart = rolloverVM.day.rangeStart
        displayNow = calendar.date(byAdding: .day, value: 1, to: displayNow)!
        rolloverVM.startUpdates()
        rolloverVM.stopUpdates()
        check(rolloverVM.day.rangeStart == historicalStart,
              "midnight preserves an explicitly selected historical day")
        for period: StatsViewModel.Tab in [.week, .month] {
            displayNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31,
                                                             hour: 23, minute: 59, second: 59))!
            let periodVM = StatsViewModel(store: store, tracker: tracker, nowProvider: { displayNow })
            periodVM.tab = period
            displayNow = calendar.date(byAdding: .day, value: 2, to: displayNow)!
            periodVM.startUpdates()
            periodVM.stopUpdates()
            check(periodVM.isViewingCurrentPeriod && calendar.isDate(periodVM.anchor, inSameDayAs: displayNow),
                  "current \(period.rawValue) statistics follow calendar boundaries")
        }
        tracker.shutdown()
        tracker.runningBrowsersProvider = { [] }
        tracker.goAuthorize()
        check(!(UserDefaults.standard.string(forKey: UsageTracker.webPermissionMessageKey) ?? "").isEmpty,
              "missing supported browser has actionable feedback")

        // v0.8.2 重置授权：tccutil 注入点 + 本地标记清理 + 预约重切
        var tccutilCalls = 0
        tracker.tccutilResetProvider = { tccutilCalls += 1 }
        UserDefaults.standard.set(true, forKey: BrowserURLReader.permissionDeniedKey)
        UserDefaults.standard.set("授权未完成，请确认浏览器已打开后重试", forKey: UsageTracker.webPermissionMessageKey)
        tracker.resetAuthorization()
        check(tccutilCalls == 1, "reset authorization clears the TCC denial record")
        check(!UserDefaults.standard.bool(forKey: BrowserURLReader.permissionDeniedKey),
              "reset authorization clears the denied flag")
        check(UserDefaults.standard.string(forKey: UsageTracker.webPermissionMessageKey) == nil,
              "reset authorization clears the stale message")
        check(UserDefaults.standard.bool(forKey: UsageTracker.webRetryPendingKey),
              "reset authorization schedules a retry")

        // v1.0 设计系统：潜水等级分档与设计稿示例一致
        check(DiveRank.rank(rate: 0.10).title == "浅水试探", "dive rank: shallow below 20%")
        check(DiveRank.rank(rate: 0.40).title == "悠然划水", "dive rank: relaxed at 40%")
        check(DiveRank.rank(rate: 0.42).title == "自由泳健将", "dive rank: swimmer at 42%")
        check(DiveRank.rank(rate: 0.69).title == "自由泳健将", "dive rank: swimmer below 70%")
        check(DiveRank.rank(rate: 0.70).title == "深海潜泳者", "dive rank: diver at 70%")

        tracker.domainProvider = { _, completion in completion(.domain("github.com")) }
        tracker.tick()
        check(!UserDefaults.standard.bool(forKey: UsageTracker.webRetryPendingKey),
              "successful read clears the reset-authorization pending banner")
        tracker.resetAuthorization()
        tracker.domainProvider = { _, completion in completion(.denied) }
        now = now.addingTimeInterval(1)
        tracker.tick()
        check(!UserDefaults.standard.bool(forKey: UsageTracker.webRetryPendingKey),
              "denied retry re-enables authorization controls")

        // The requested category colors use explicit sRGB tokens.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            Palette.workNS.usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            check(abs(red - 0.137) < 0.005 && abs(green - 0.702) < 0.005 && abs(blue - 0.659) < 0.005,
                  "work color is teal #23B3A8")
            Palette.slackNS.usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            check(abs(red - 0.941) < 0.005 && abs(green - 0.584) < 0.005 && abs(blue - 0.173) < 0.005,
                  "leisure color is orange #F0952C")
        }

        // 菜单栏药丸可绘制且非模板图
        let pill = MenuBarPill.image(style: .rate, text: "42%")
        check(pill.size.width > 20, "pill image sizes to its content")
        check(!pill.isTemplate, "pill renders in color, not as a template")
        check(pill.tiffRepresentation?.count ?? 0 > 0, "pill image renders to bitmap")

        let bundlePlist = NSDictionary(contentsOfFile: "App/Info.plist")
        check(!(bundlePlist?["NSAppleEventsUsageDescription"] as? String ?? "").isEmpty,
              "application includes required Apple events purpose string")
        if failures > 0 { exit(1) }
    }
}
