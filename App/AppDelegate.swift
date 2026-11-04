import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var store: Store!
    private var tracker: UsageTracker!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[MoyuTimer] applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        do {
            store = try Store()
        } catch {
            print("[MoyuTimer] Store 初始化失败: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "无法初始化数据库"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        print("[MoyuTimer] Store 就绪: \(store.databaseURL.path)")

        tracker = UsageTracker(store: store)
        statusBar = StatusBarController(store: store, tracker: tracker)
        tracker.start()
        print("[MoyuTimer] 采集器与菜单栏已启动")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        tracker?.shutdown()   // 退出前结算打开中的会话
        return .terminateNow
    }
}
