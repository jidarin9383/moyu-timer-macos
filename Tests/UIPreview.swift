import Cocoa
import SwiftUI

/// Synthetic, isolated native snapshots; never starts background tracking or requests permissions.
@main
struct UIPreview {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/moyu-native-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MoyuUIPreview-\(UUID())")
        setenv("MOYU_DB_DIR", temporary.path, 1)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let interactive = CommandLine.arguments.contains("--interactive") || Bundle.main.bundleIdentifier == "com.darinji.moyutimer.uiqa"
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let calendar = DayRange.localCalendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 18))!
        let today = calendar.startOfDay(for: now)
        let store = try Store()
        func record(_ bundle: String, _ name: String, _ minutes: Int, domain: String? = nil, day: Date = today) {
            let session = store.openSession(bundleId: bundle, name: name, domain: domain, start: day.addingTimeInterval(60))
            store.closeSession(rowId: session.rowId, endTs: Int(day.timeIntervalSince1970) + 60 + minutes * 60)
        }
        record("com.apple.dt.Xcode", "Xcode", 105)
        record("com.figma.Desktop", "Figma", 65)
        record("com.apple.Terminal", "Terminal", 28)
        for bundle in ["com.apple.dt.Xcode", "com.figma.Desktop", "com.apple.Terminal"] {
            store.setCategory(appId: store.appId(bundleId: bundle)!, category: .work)
        }
        record(WebGroup.bundleId, WebGroup.name, 42, domain: "bilibili.com")
        record(WebGroup.bundleId, WebGroup.name, 16, domain: "xiaohongshu.com")
        record(WebGroup.bundleId, WebGroup.name, 10, domain: "v2ex.com")
        for domain in ["bilibili.com", "xiaohongshu.com", "v2ex.com"] { store.setDomainCategory(domain: domain, category: .slack) }
        record("com.tencent.xinWeChat", "微信", 24)
        store.setCategory(appId: store.appId(bundleId: "com.tencent.xinWeChat")!, category: .slack)
        let monthStart = Date(timeIntervalSince1970: Double(DayRange.month(today).start))
        let records = [[1,240,50],[2,260,80],[3,90,110],[5,280,40],[6,270,60],[7,230,90],[8,260,65],
                       [9,250,75],[10,100,140],[11,60,120],[12,250,75],[13,320,100],[14,230,130],[15,270,80],[16,240,50]]
        for row in records {
            let date = calendar.date(byAdding: .day, value: row[0] - 1, to: monthStart)!
            record("com.apple.dt.Xcode", "Xcode", row[1], day: date)
            record(WebGroup.bundleId, WebGroup.name, row[2], domain: "bilibili.com", day: date)
        }
        let tracker = UsageTracker(store: store)
        tracker.nowProvider = { now }; tracker.frontmostProvider = { nil }; tracker.passiveSignalProvider = { _, _ in false }
        let vm = StatsViewModel(store: store, tracker: tracker, nowProvider: { now })
        var settingsWindow: NSWindow?
        let root = PopoverView(store: store, tracker: tracker, vm: vm,
                              motionEnabled: interactive) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "偏好设置 · 独立测试"
            window.contentView = NSHostingView(rootView: SettingsView(store: store, tracker: tracker, checksBrowserPermission: false))
            window.isReleasedWhenClosed = false
            settingsWindow = window
            window.center(); window.makeKeyAndOrderFront(nil)
        }
        UserDefaults.standard.set(false, forKey: BrowserURLReader.permissionDeniedKey)
        UserDefaults.standard.set(false, forKey: UsageTracker.webRetryPendingKey)
        UserDefaults.standard.removeObject(forKey: UsageTracker.webPermissionMessageKey)
        func save<V: View>(_ view: V, _ name: String, width: CGFloat = 348, height: CGFloat = 460, dark: Bool) throws {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            application.appearance = appearance
            let host = NSHostingView(rootView: view.frame(width: width, height: height)
                .environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = appearance
            let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: width, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance; window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let path = output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: path)
            print(path.path)
            window.contentView = nil
        }
        if interactive {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 348, height: 460),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "摸了个鱼 · UI 验收"
            window.contentView = NSHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            window.center(); window.makeKeyAndOrderFront(nil)
            application.setActivationPolicy(.regular)
            application.activate(ignoringOtherApps: true)
            application.run()
            withExtendedLifetime(settingsWindow) {}
            return
        }
        for dark in [false, true] {
            vm.backToToday(); vm.tab = .day
            try save(root, "01-day", dark: dark)
            tracker.setPaused(true)
            try save(root, "02-paused", dark: dark)
            tracker.setPaused(false)
            if let web = vm.day.apps.first(where: { $0.bundleId == WebGroup.bundleId && $0.category == .slack }) {
                try save(VStack(spacing: 0) {
                    AppRow(app: web, categoryTotalMs: 92 * 60_000, expanded: true, liveMs: 0)
                    WebDomainList(store: store, app: web, category: .slack, from: vm.day.rangeStart, to: vm.day.rangeEnd)
                    ForEach(vm.day.apps.filter { $0.bundleId != WebGroup.bundleId }) { app in
                        AppRow(app: app, categoryTotalMs: 0, expanded: false, liveMs: 0)
                    }
                    Spacer()
                }.background(AquariumStyle.background), "03-domains", height: 300, dark: dark)
            }
            vm.tab = .week
            try save(root, "04-week", dark: dark)
            vm.previous()
            try save(root, "05-previous-week", dark: dark)
            vm.backToToday(); vm.tab = .month
            try save(root, "06-month", dark: dark)
            try save(MonthHeatmap(snapshot: vm.month, live: nil, hoveredDate: today, now: now)
                .padding(14).background(AquariumStyle.background), "07-month-hover", height: 280, dark: dark)
            vm.previous()
            try save(root, "08-empty-month", dark: dark)
            vm.tab = .day
            try save(root, "09-empty-day", dark: dark)
            vm.backToToday()
            UserDefaults.standard.set(true, forKey: BrowserURLReader.permissionDeniedKey)
            try save(root, "10-permission", dark: dark)
            UserDefaults.standard.set("Firefox 需要辅助功能权限，请在系统设置中允许「摸了个鱼」读取当前网页地址。", forKey: UsageTracker.webPermissionMessageKey)
            try save(root, "13-firefox-permission", dark: dark)
            UserDefaults.standard.removeObject(forKey: UsageTracker.webPermissionMessageKey)
            UserDefaults.standard.set(false, forKey: BrowserURLReader.permissionDeniedKey)
            try save(SettingsView(store: store, tracker: tracker, checksBrowserPermission: false), "11-settings", width: 440, height: 400, dark: dark)
        }
    }
}
