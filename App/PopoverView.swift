import SwiftUI

/// Native Pocket Aquarium; snapshots keep stable identities and refresh only on stored changes.
struct PopoverView: View {
    @ObservedObject var vm: StatsViewModel
    @ObservedObject private var tracker: UsageTracker
    private let motionEnabled: Bool
    private let onOpenSettings: () -> Void
    @AppStorage(BrowserURLReader.permissionDeniedKey) private var webPermissionDenied = false
    @AppStorage(UsageTracker.webRetryPendingKey) private var webRetryPending = false
    @AppStorage(UsageTracker.webPermissionMessageKey) private var webPermissionMessage = ""

    init(store: Store, tracker: UsageTracker, vm: StatsViewModel, motionEnabled: Bool = true, onOpenSettings: @escaping () -> Void) {
        self.motionEnabled = motionEnabled
        self.vm = vm
        self.tracker = tracker
        self.onOpenSettings = onOpenSettings
    }

    private var totals: [AppCategory: Int] {
        var values: [AppCategory: Int]
        switch vm.tab {
        case .day: values = vm.day.categoryTotals
        case .week: values = vm.week.categoryTotals
        case .month: values = vm.month.categoryTotals
        }
        if let live = vm.liveForCurrentRange { values[live.category, default: 0] += live.ms }
        return values
    }
    private var summary: AquariumSummary {
        AquariumSummary(workMs: totals[.work] ?? 0, slackMs: totals[.slack] ?? 0)
    }
    private var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = DayRange.localCalendar
        switch vm.tab {
        case .day:
            formatter.dateFormat = DayRange.localCalendar.isDate(vm.anchor, equalTo: Date(), toGranularity: .year)
                ? "M月d日 EEE" : "yyyy年M月d日"
            return formatter.string(from: vm.anchor) + (vm.isViewingCurrentPeriod ? " (今日)" : "")
        case .week:
            return (vm.isViewingCurrentPeriod ? "本周 · " : "")
                + Formatters.dateRangeTitle(start: vm.currentRange.start, end: vm.currentRange.end)
        case .month:
            formatter.dateFormat = "yyyy年 M月"
            return formatter.string(from: vm.anchor)
        }
    }
    private var trailing: String {
        guard vm.tab == .week else { return "" }
        return "\(vm.isViewingCurrentPeriod ? "本周" : "该周")摸鱼率 " + (summary.rate.map { "\($0)%" } ?? "—")
    }

    var body: some View {
        AquariumShell(tab: vm.tab, paused: tracker.isPaused,
                      onTab: { vm.tab = $0 }, onSettings: onOpenSettings,
                      onPause: { tracker.setPaused(!tracker.isPaused); vm.rebuildSnapshots() },
                      onQuit: { NSApp.terminate(nil) }) {
            VStack(spacing: 0) {
                AquariumNavigator(title: title, tab: vm.tab, current: vm.isViewingCurrentPeriod,
                                  canGoNext: vm.canGoNext, previous: vm.previous, next: vm.next,
                                  back: vm.backToToday, trailing: trailing)
                if vm.tab == .day {
                    AquariumHabitat(summary: summary, paused: tracker.isPaused, motionEnabled: motionEnabled)
                    AquariumDaySummary(summary: summary)
                    DayView(snapshot: vm.day, store: vm.store, live: vm.liveForCurrentRange,
                            permission: permissionState, onAuthorize: tracker.goAuthorize)
                } else {
                    PeriodView(period: vm.tab, snapshot: vm.tab == .week ? vm.week : vm.month,
                               store: vm.store, live: vm.liveForCurrentRange, now: vm.now)
                }
            }
        }
    }

    private var permissionState: String? {
        guard webPermissionDenied || webRetryPending || !webPermissionMessage.isEmpty else { return nil }
        if webRetryPending { return "请在系统弹窗中完成浏览器授权" }
        return webPermissionMessage.isEmpty ? "部分浏览器尚未授权，网页时长暂不计入" : webPermissionMessage
    }
}
