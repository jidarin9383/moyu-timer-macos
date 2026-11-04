import Cocoa

@main
struct BrowserAuthorizationRegression {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "PASS" : "FAIL") \(description)")
            if !condition { failures += 1 }
        }
        let chrome = "com.google.Chrome", brave = "com.brave.Browser", safari = "com.apple.Safari"
        var running: [String] = []
        var permissions: [String: BrowserPermissionResult] = [:]
        var requested: [String] = []
        var managed = 0
        var checks: [[String]] = []
        var delayed: [([String: BrowserPermissionResult]) -> Void] = []
        var delay = false
        let model = BrowserAuthorizationModel(runningBrowsers: { running }, check: { browsers, reply in
            checks.append(browsers)
            if delay { delayed.append(reply) } else { reply(permissions) }
        }, request: { requested.append($0) }, manage: { managed += 1 })

        model.refresh()
        check(!model.canAct && checks.isEmpty, "no running browser needs no permission query")
        running = [brave]
        model.refresh()
        check(model.canAct && model.needsAuthorization && requested.isEmpty,
              "opening a supported alternative browser exposes consent without prompting during refresh")
        model.performAction()
        check(requested == [brave], "a fresh user can request consent for the actual running browser")
        permissions[brave] = .authorized
        model.refresh()
        check(!model.needsAuthorization && model.status.contains("已授权"), "successful consent updates the unified status")

        running = [chrome, brave]
        permissions = [chrome: .authorized, brave: .denied]
        model.performAction()
        check(requested.last == brave && managed == 0,
              "a newly opened unapproved browser is selected ahead of an approved browser")
        running = [chrome]
        model.performAction()
        check(managed == 1 && requested.count == 2, "a closed pending browser is not authorized from stale UI state")
        running = ["com.qihoo.litebrowserx", "com.example.editor", chrome, chrome]
        model.refresh()
        check(checks.last == [chrome], "only supported running browsers are checked, once each")
        running = []
        model.performAction()
        check(managed == 1 && requested.count == 2 && !model.canAct,
              "no browser action neither launches apps nor opens unrelated settings")

        delay = true
        running = [brave]
        model.refresh()
        running = [safari]
        model.refresh()
        delayed.removeFirst()([brave: .authorized])
        check(model.needsAuthorization, "an obsolete permission result cannot mark a different browser as approved")
        delayed.removeFirst()([safari: .denied])
        model.performAction()
        running = [brave]
        delayed.removeFirst()([safari: .denied])
        check(requested.count == 2 && delayed.count == 1,
              "a browser closing during the permission check rechecks the live browser set")
        delayed.removeFirst()([brave: .denied])
        check(requested == [brave, brave, brave], "the explicit authorization intent survives a live-browser change")
        if failures > 0 { exit(1) }
    }
}
