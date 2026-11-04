import Cocoa

/// Statistics refresh only when stored data changes. Stable row identities preserve scrolling.
final class StatsViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case day = "日"
        case week = "周"
        case month = "月"
        var id: String { rawValue }
    }

    struct DaySnapshot: Equatable {
        var categoryTotals: [AppCategory: Int]
        var apps: [AppUsageRow]
        let rangeStart: Int
        let rangeEnd: Int
        static let empty = DaySnapshot(categoryTotals: [:], apps: [], rangeStart: 0, rangeEnd: 0)
    }

    struct RangeSnapshot: Equatable {
        var categoryTotals: [AppCategory: Int]
        var daily: [DayCategoryUsage]
        var apps: [AppUsageRow]
        let rangeStart: Int
        let rangeEnd: Int
        static let empty = RangeSnapshot(categoryTotals: [:], daily: [], apps: [], rangeStart: 0, rangeEnd: 0)
    }

    /// 打开中会话的实时增量：每秒变化的三个标量（不触发 SQL、不替换快照数组）。
    /// appId 用于把增量叠加到对应行；idle/锁屏/无会话时为 nil。
    struct LiveInfo: Equatable {
        let ms: Int
        let category: AppCategory
        let appId: Int64
    }

    @Published private(set) var day: DaySnapshot = .empty
    @Published private(set) var week: RangeSnapshot = .empty
    @Published private(set) var month: RangeSnapshot = .empty
    @Published private(set) var live: LiveInfo?
    @Published var tab: Tab = .day { didSet { rebuildSnapshots() } }
    @Published var anchor: Date { didSet { rebuildSnapshots() } }

    let store: Store
    private let tracker: UsageTracker
    private let nowProvider: () -> Date
    private var lastObservedDate: Date
    private var timer: Timer?
    private var lastStoreRevision: UInt64 = 0
    private var lastRangeStart = 0

    init(store: Store, tracker: UsageTracker, nowProvider: @escaping () -> Date = Date.init) {
        self.store = store
        self.tracker = tracker
        self.nowProvider = nowProvider
        let now = nowProvider()
        self.anchor = now
        self.lastObservedDate = now
        rebuildSnapshots()
        updateLive()
        // 用户改分类（右键/展开区/网址右键）后即时重建，不必等 2s 周期
        store.onChange = { [weak self] in
            self?.rebuildSnapshots()
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - 刷新生命周期（Popover 显示时跑，隐藏时停）

    func startUpdates() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)   // 菜单展开/滚动期间也继续走
    }

    func stopUpdates() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = nowProvider()
        if !DayRange.localCalendar.isDate(lastObservedDate, inSameDayAs: now) {
            let previousTimestamp = Int(lastObservedDate.timeIntervalSince1970)
            let range = currentRange
            lastObservedDate = now
            if range.start <= previousTimestamp && previousTimestamp < range.end {
                anchor = now
                return
            }
        }
        if store.revision != lastStoreRevision || currentRange.start != lastRangeStart {
            rebuildSnapshots()
        } else {
            updateLive()
        }
    }

    /// 每秒更新实时增量标量（内存计算，零 SQL）。
    private func updateLive() {
        guard isViewingCurrentPeriod, let delta = tracker.liveDelta(),
              let appId = tracker.liveSession?.appId else {
            if live != nil { live = nil }
            return
        }
        let next = LiveInfo(ms: delta.ms, category: delta.category, appId: appId)
        if live != next { live = next }
    }

    /// 重建当前 tab 的快照（结构性数据）。live 不在这里累加——由展示层叠加，
    /// 避免「快照含 live」导致 struct 每秒被替换、退回全量 diff 老路。
    func rebuildSnapshots() {
        lastStoreRevision = store.revision
        lastRangeStart = currentRange.start
        switch tab {
        case .day:
            let next = DaySnapshot(
                categoryTotals: store.categoryTotals(from: DayRange.day(anchor).start, to: DayRange.day(anchor).end),
                apps: store.appUsage(from: DayRange.day(anchor).start, to: DayRange.day(anchor).end),
                rangeStart: DayRange.day(anchor).start, rangeEnd: DayRange.day(anchor).end)
            if day != next { day = next }
        case .week:
            let range = DayRange.week(anchor)
            let next = RangeSnapshot(
                categoryTotals: store.categoryTotals(from: range.start, to: range.end),
                daily: store.dailyBreakdown(from: range.start, to: range.end),
                apps: store.appUsage(from: range.start, to: range.end),
                rangeStart: range.start, rangeEnd: range.end)
            if week != next { week = next }
        case .month:
            let range = DayRange.month(anchor)
            let next = RangeSnapshot(
                categoryTotals: store.categoryTotals(from: range.start, to: range.end),
                daily: store.dailyBreakdown(from: range.start, to: range.end),
                apps: store.appUsage(from: range.start, to: range.end),
                rangeStart: range.start, rangeEnd: range.end)
            if month != next { month = next }
        }
        updateLive()
    }

    var now: Date { nowProvider() }

    // MARK: - 导航

    var currentRange: (start: Int, end: Int) {
        switch tab {
        case .day: return DayRange.day(anchor)
        case .week: return DayRange.week(anchor)
        case .month: return DayRange.month(anchor)
        }
    }

    /// A live interval belongs only to the period that contains the current time.
    var liveForCurrentRange: LiveInfo? {
        let range = currentRange
        let now = Int(nowProvider().timeIntervalSince1970)
        guard range.start <= now, now < range.end else { return nil }
        return live
    }

    var isViewingCurrentPeriod: Bool {
        let now = nowProvider()
        switch tab {
        case .day: return DayRange.day(now).start == DayRange.day(anchor).start
        case .week: return DayRange.week(now).start == DayRange.week(anchor).start
        case .month: return DayRange.month(now).start == DayRange.month(anchor).start
        }
    }

    func previous() { shiftAnchor(-1) }
    func next() { shiftAnchor(1) }
    func backToToday() { anchor = nowProvider() }

    /// Explicit navigation helper; hover-only charts do not invoke it.
    func jumpToDay(_ date: Date) {
        tab = .day
        anchor = date
    }

    /// 能否向后翻：最多翻到「今天所在的周期」，今天之后的日期不展示。
    var canGoNext: Bool {
        let now = nowProvider()
        switch tab {
        case .day: return DayRange.day(anchor).start < DayRange.day(now).start
        case .week: return DayRange.week(anchor).start < DayRange.week(now).start
        case .month: return DayRange.month(anchor).start < DayRange.month(now).start
        }
    }

    private func shiftAnchor(_ value: Int) {
        if value > 0 && !canGoNext { return }   // 不允许翻到未来
        let component: Calendar.Component
        switch tab {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        if let new = DayRange.localCalendar.date(byAdding: component, value: value, to: anchor) {
            anchor = new
        }
    }

    // MARK: - live 叠加（展示层用）

    /// 某分类总时长应叠加的实时增量（当前 live 属于该分类时）。
    func liveExtra(_ category: AppCategory) -> Int {
        guard let live, live.category == category else { return 0 }
        return live.ms
    }

    /// 某行应叠加的实时增量（当前 live 属于该行时）。
    func liveExtra(appId: Int64) -> Int {
        guard let live, live.appId == appId else { return 0 }
        return live.ms
    }
}
