import Cocoa

@main
struct BrowserSupportRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoyuBrowserSupport-\(UUID())")
        setenv("MOYU_DB_DIR", directory.path, 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store()
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "PASS" : "FAIL") \(description)")
            if !condition { failures += 1 }
        }
        let browsers = [
            ("com.tencent.qqbrowserappmac", "QQBrowser"),
            ("com.quark.desktop", "Quark"),
            ("net.qihoo.360browser", "360Chrome"),
            ("company.thebrowser.dia", "Dia"),
            ("ai.perplexity.comet", "Comet"),
            ("com.kagi.kagimacOS", "Orion")
        ]
        let start = DayRange.localCalendar.startOfDay(for: Date()).addingTimeInterval(60)
        var now = start
        for (bundle, name) in browsers {
            let expectedProperty = name == "Orion" ? "URL of current tab of front window" : "URL of active tab of front window"
            check(WebGroup.urlQueryProperty(bundle) == expectedProperty,
                  "\(name) uses the URL property exposed by its inspected scripting dictionary")
            let tracker = UsageTracker(store: store)
            tracker.nowProvider = { now }
            tracker.idleProvider = { 0 }
            tracker.passiveSignalProvider = { _, _ in false }
            tracker.frontmostProvider = { (bundle, name) }
            tracker.runningBrowsersProvider = { [bundle] }
            var consentTarget: String?
            tracker.authorizationProvider = { target, reply in consentTarget = target; reply(.authorized) }
            let model = BrowserAuthorizationModel(runningBrowsers: { [bundle] }, check: { _, reply in reply([:]) },
                                                   request: { tracker.goAuthorize(bundleId: $0) }, manage: {})
            model.refresh()
            model.performAction()
            check(model.canAct && consentTarget == bundle, "\(name) is discovered and explicitly authorized through the unified entry")
            tracker.domainProvider = { _, reply in reply(.domain("github.com")) }
            tracker.tick()
            check(tracker.liveSession?.bundleId == WebGroup.bundleId && tracker.liveSession?.domain == "github.com",
                  "\(name) records a successfully read URL in the shared website group")
            now.addTimeInterval(3)
            tracker.shutdown()

            let denied = UsageTracker(store: store)
            denied.nowProvider = { now }
            denied.idleProvider = { 0 }
            denied.passiveSignalProvider = { _, _ in false }
            denied.frontmostProvider = { (bundle, name) }
            denied.domainProvider = { _, reply in reply(.denied) }
            denied.tick()
            check(denied.liveSession == nil, "\(name) never counts denied website time as a native app")
            denied.shutdown()
        }
        let range = DayRange.day(start)
        check(store.appUsage(from: range.start, to: range.end).filter { $0.bundleId == WebGroup.bundleId }.reduce(0) { $0 + $1.ms } == browsers.count * 3_000,
              "new browsers reconcile to one website total without double counting")

        let native = store.openSession(bundleId: "com.tencent.qqbrowserappmac", name: "QQBrowser", start: now)
        store.closeSession(rowId: native.rowId, endTs: Int(now.timeIntervalSince1970) + 2)
        let previousNativeMs = store.sessions(appId: native.appId, from: range.start, to: range.end)
            .reduce(0) { $0 + $1.durationMs }
        let reopened = try Store()
        let reopenedNativeMs = reopened.sessions(appId: native.appId, from: range.start, to: range.end)
            .reduce(0) { $0 + $1.durationMs }
        check(previousNativeMs >= 2_000 && reopenedNativeMs == previousNativeMs
              && !reopened.appUsage(from: range.start, to: range.end).contains { $0.bundleId == "com.tencent.qqbrowserappmac" },
              "browser-native history stays in raw storage but never appears as counted application usage")
        let legacy = reopened.openSession(bundleId: "com.google.Chrome", name: "Chrome", start: now.addingTimeInterval(2))
        reopened.closeSession(rowId: legacy.rowId, endTs: Int(now.timeIntervalSince1970) + 4)
        let migrated = try Store()
        let migratedRows = migrated.appUsage(from: range.start, to: range.end)
        check(!migratedRows.contains { $0.bundleId == "com.google.Chrome" }
              && !migratedRows.contains { $0.bundleId == "com.tencent.qqbrowserappmac" }
              && migrated.sessions(appId: native.appId, from: range.start, to: range.end).reduce(0) { $0 + $1.durationMs } == previousNativeMs,
              "legacy migration remains compatible with website-only totals and preserved raw records")
        check(!WebGroup.isBrowser("com.tencent.qq") && !WebGroup.isBrowser("com.tencent.xinWeChat"),
              "QQ and WeChat messaging apps are never mistaken for QQ Browser")
        check(WebGroup.urlQueryProperty("com.qihoo.litebrowserx") == nil && WebGroup.urlQueryProperty("com.example.unknown") == nil,
              "unsupported applications have no URL query capability or consent target")
        check(WebGroup.urlQueryProperty("com.apple.Safari") == "URL of current tab of front window"
              && WebGroup.urlQueryProperty("com.google.Chrome") == "URL of active tab of front window",
              "existing Safari and Chrome URL adapters stay compatible")
        if failures > 0 { exit(1) }
    }
}
