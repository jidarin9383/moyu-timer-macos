import Cocoa

@main
struct FirefoxRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoyuFirefox-\(UUID())")
        setenv("MOYU_DB_DIR", directory.path, 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store()
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "PASS" : "FAIL") \(description)")
            if !condition { failures += 1 }
        }
        let firefox = "org.mozilla.firefox"
        let tracker = UsageTracker(store: store)
        tracker.runningBrowsersProvider = { [firefox] }
        tracker.frontmostProvider = { ("com.example.own-ui", "Test UI") }
        var targets: [String] = []
        tracker.authorizationProvider = { target, reply in targets.append(target); reply(.authorized) }
        let model = BrowserAuthorizationModel(runningBrowsers: { [firefox] }, check: { _, reply in reply([:]) },
                                               request: { tracker.goAuthorize(bundleId: $0) }, manage: {})
        model.refresh()
        model.performAction()
        check(model.canAct && model.needsAuthorization, "Firefox appears in the unified authorization entry")
        check(targets == [firefox], "explicit Firefox consent works while our own UI is frontmost")
        var accessibilitySettings = 0, automationSettings = 0
        tracker.openAccessibilitySettingsProvider = { accessibilitySettings += 1 }
        tracker.openAutomationSettingsProvider = { automationSettings += 1 }
        tracker.authorizationProvider = { _, reply in reply(.denied) }
        tracker.goAuthorize(bundleId: firefox)
        check(accessibilitySettings == 1 && automationSettings == 0,
              "denied Firefox consent opens Accessibility instead of Automation settings")
        check((UserDefaults.standard.string(forKey: UsageTracker.webPermissionMessageKey) ?? "").contains("辅助功能"),
              "Firefox consent explains which system permission is required")
        tracker.openBrowserPermissionSettings()
        check(accessibilitySettings == 2 && automationSettings == 0,
              "managing the only running Firefox opens the correct system pane")

        let page = "https://example.org/path?query=value"
        check(FirefoxURLReader.selectedURL(windowDocument: nil, webAreaURLs: [page]) == page,
              "a single committed document retains its complete URL")
        check(FirefoxURLReader.selectedURL(windowDocument: page, webAreaURLs: []) == page,
              "a focused window document can supply its URL without reading page descendants")
        check(FirefoxURLReader.selectedURL(windowDocument: nil, webAreaURLs: [page, "https://other.example/"]) == nil,
              "multiple top-level web documents are rejected rather than misattributed")
        check(FirefoxURLReader.selectedURL(windowDocument: nil, webAreaURLs: [nil]) == nil,
              "a missing document URL never falls back to editable address text")
        for value in ["about:newtab", "about:preferences", "file:///tmp/example.html", "javascript:alert(1)", "typed search", "example.org"] {
            check(FirefoxURLReader.selectedURL(windowDocument: nil, webAreaURLs: [value]) == nil,
                  "Firefox excludes non-committed or non-web URL: \(value)")
        }
        check(FirefoxURLReader.selectedURL(windowDocument: "about:preferences", webAreaURLs: [page]) == nil,
              "an internal focused window cannot attribute a background web page")
        if case .videoPage("bilibili.com") = BrowserURLReader.classifyURL("https://www.bilibili.com/video/BV1test") {
            check(true, "Firefox shares existing video-page classification")
        } else { check(false, "Firefox shares existing video-page classification") }
        if case .failed = FirefoxURLReader.currentDomain(bundleId: "com.example.unrelated") {
            check(true, "the Accessibility reader refuses every unrelated application")
        } else { check(false, "the Accessibility reader refuses every unrelated application") }

        let start = DayRange.localCalendar.startOfDay(for: Date()).addingTimeInterval(60)
        var now = start
        tracker.nowProvider = { now }
        tracker.idleProvider = { 0 }
        tracker.passiveSignalProvider = { _, _ in false }
        tracker.frontmostProvider = { (firefox, "Firefox") }
        var reply: ((URLQueryResult) -> Void)?
        tracker.domainProvider = { _, completion in reply = completion }
        tracker.tick()
        tracker.setPaused(true)
        reply?(.domain("example.org"))
        check(tracker.liveSession == nil, "a delayed Firefox URL cannot reopen a manually paused session")
        tracker.setPaused(false)
        tracker.tick()
        reply?(.domain("example.org"))
        check(tracker.liveSession?.bundleId == WebGroup.bundleId,
              "Firefox counts only inside the shared website group")
        now.addTimeInterval(5)
        tracker.shutdown()
        let range = DayRange.day(start)
        let rows = store.appUsage(from: range.start, to: range.end)
        check(rows.reduce(0) { $0 + $1.ms } == 5_000 && rows.allSatisfy { $0.bundleId == WebGroup.bundleId },
              "Firefox produces website time without a separate native-app row")
        if failures > 0 { exit(1) }
    }
}
