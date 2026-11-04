import Cocoa
import SwiftUI
import ServiceManagement

/// 菜单栏控制器：状态栏图标（默认显示摸鱼率）、Popover、右键菜单、设置窗口。
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: Store
    private let tracker: UsageTracker
    private let vm: StatsViewModel          // 强引用：驱动 Popover 刷新生命周期
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var settingsWindow: NSWindow?

    init(store: Store, tracker: UsageTracker) {
        self.store = store
        self.tracker = tracker
        self.vm = StatsViewModel(store: store, tracker: tracker)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = NSFont.menuBarFont(ofSize: 0)
        }

        let rootView = PopoverView(store: store, tracker: tracker, vm: vm) { [weak self] in
            self?.openSettings()
        }
        let hosting = NSHostingController(rootView: rootView)
        // v0.9：不用 .intrinsicContentSize——它会让 popover 窗口跟着内容每秒 resize
        // （实时时长数字一直在变），高频 resize 下滚动/交互直接卡死（用户反馈
        // 「下滑会卡住，现在卡住了」）。改为固定 340×460，内容超出由内部 ScrollView 滚。
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatusItem()
        }
        updateStatusItem()
    }

    // MARK: 菜单栏图标（v1.0 设计稿：鱼形药丸，四种形态）

    private func updateStatusItem() {
        let range = DayRange.day(Date())
        var totals = store.categoryTotals(from: range.start, to: range.end)
        if let live = tracker.liveDelta() {
            totals[live.category, default: 0] += live.ms
        }
        let work = totals[.work] ?? 0
        let slack = totals[.slack] ?? 0
        let counted = work + slack
        let rate = counted > 0 ? Int((Double(slack) / Double(counted) * 100).rounded()) : 0

        // 形态偏好持久化（右键「菜单栏显示」切换）
        let style = MenuBarStyle.current
        let image: NSImage
        switch style {
        case .rate:
            image = MenuBarPill.image(style: .rate, text: "\(rate)%")
        case .duration:
            image = MenuBarPill.image(style: .duration, text: Formatters.duration(slack))
        case .spark:
            image = MenuBarPill.image(style: .spark, text: "", spark: hourlySpark())
        case .plain:
            image = MenuBarPill.image(style: .plain, text: "")
        }
        statusItem.button?.image = image
        statusItem.button?.title = ""
        statusItem.button?.toolTip = String(
            format: "摸了个鱼\n今日 工作 %@ · 摸鱼 %@ · 已忽略 %@",
            Formatters.duration(work), Formatters.duration(slack), Formatters.duration(totals[.ignored] ?? 0)
        )
    }

    /// 近 4 个整点小时的摸鱼量，归一化到 0...1（迷你柱图形态用）。
    private func hourlySpark() -> [Double] {
        let now = Date()
        var values: [Double] = []
        var maxValue = 0.0
        for offset in (0..<4).reversed() {
            guard let hourStart = Calendar.current.date(byAdding: .hour, value: -offset, to: now),
                  let hourEnd = Calendar.current.date(byAdding: .hour, value: 1, to: hourStart)
            else { continue }
            let from = Int(hourStart.timeIntervalSince1970)
            let to = min(Int(hourEnd.timeIntervalSince1970), Int(now.timeIntervalSince1970))
            let ms = store.categoryTotals(from: from, to: to)[.slack] ?? 0
            let hours = Double(ms) / 3_600_000
            values.append(hours)
            maxValue = max(maxValue, hours)
        }
        guard maxValue > 0 else { return values }
        return values.map { $0 / maxValue }
    }

    @objc private func statusBarClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        tracker.suspendForOwnUI()   // 看统计的时间不算进任何一个 App
        guard let button = statusItem.button else { return }
        popover.contentSize = NSSize(width: 348, height: 460)   // 固定尺寸（v0.9：不再每秒 resize）
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSPopoverDelegate（v0.9：可见时才跑每秒刷新，后台零开销）

    func popoverWillShow(_ notification: Notification) {
        vm.rebuildSnapshots()   // 打开时拿最新结构（隐藏期间可能有新会话/改分类）
        vm.startUpdates()
    }

    func popoverWillClose(_ notification: Notification) {
        vm.stopUpdates()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let loginTitle = SMAppService.mainApp.status == .enabled ? "关闭登录自启" : "登录时打开"
        menu.addItem(withTitle: loginTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

        // 「菜单栏显示」子菜单：四种药丸形态
        let displayItem = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let currentStyle = MenuBarStyle.current
        for style in MenuBarStyle.allCases {
            let item = NSMenuItem(title: style.rawValue, action: #selector(selectMenuBarStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
            item.state = style == currentStyle ? .on : .off
            submenu.addItem(item)
        }
        displayItem.submenu = submenu
        menu.addItem(displayItem)

        menu.addItem(withTitle: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items {
            item.target = self
        }
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func selectMenuBarStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? MenuBarStyle else { return }
        MenuBarStyle.current = style
        updateStatusItem()
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 设置窗口

    func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(store: store, tracker: tracker))
        hosting.sizingOptions = [.intrinsicContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "偏好设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.setContentSize(NSSize(width: 440, height: 400))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
