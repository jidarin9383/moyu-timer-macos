import Cocoa

/// Tracks foreground sessions and counts browser time only after a successful URL read.
/// Consent requests are explicit and independent of the current foreground application.
final class UsageTracker: ObservableObject {
    @Published private(set) var isPaused = false
    private let store: Store
    private var timer: Timer?
    private var open: OpenSession?

    private let flushInterval: TimeInterval = 15   // 进行中会话落盘间隔
    private let urlQueryInterval: TimeInterval = 5 // 浏览器 URL 查询间隔（PRD F7）
    private let urlQueryTimeout: TimeInterval = 1  // 超过视为「拿不到」：主动停计
    private let videoIdleThreshold: TimeInterval = 1800      // 视频页「从未见过信号」时的闲置阈值（§0：固定 30 分钟）
    private let passiveCap: TimeInterval = 10_800            // 有信号时无输入硬上限（3 小时）
    private let signalSampleInterval: TimeInterval = 2       // 信号采样间隔
    private let signalFreshness: TimeInterval = 6            // 阳性信号保鲜期
    private let signalSampleMinIdle: TimeInterval = 10       // 空闲超过该值才采样

    /// 网页查询状态
    private var lastURLQueryAt: Date = .distantPast
    private var lastBrowserBundleId: String?       // 前台浏览器身份（Chrome→Safari 要立即重查）
    private var webQueryInFlight = false
    private var webQueryStartedAt: Date = .distantPast
    private var webQueryExpired = false            // 超时后迟到的结果：不补计等待时间
    private var webQueryForcePending = false       // 因串行化被跳过的强制查询（切浏览器）
    private var webGeneration: UInt64 = 0          // 失效的查询不得重新打开旧会话
    private var mostRecentBrowserBundleId: String?
    private var authorizationInFlight = false
    private var webRetryRequested = false          // 用户点了「重试/重置授权」但当时前台不是浏览器：切到浏览器后自动重查

    /// Lock and sleep can overlap; waking must not clear an active screen lock.
    private var isScreenLocked = false
    private var isSleeping = false
    /// 屏保与熄屏无事件配对（§3.2）：靠「标记后又有输入」在 tick 里自愈。
    private var isScreenSaverActive = false
    private var screenSaverSetAt: Date = .distantPast
    private var isDisplayAsleep = false
    private var displayAsleepSetAt: Date = .distantPast
    private var isExcluded: Bool { isPaused || isScreenLocked || isSleeping || isScreenSaverActive || isDisplayAsleep }

    /// 被动使用信号（保持屏幕常亮 / 浏览器出声）最近一次阳性观测
    private var lastSignalAt: Date?
    private var lastSignalSampleAt: Date = .distantPast

    // MARK: 测试注入点（生产走默认实现；无头测试替换以驱动确定性时序）

    /// 查询浏览器当前网址。默认走 BrowserURLReader。
    var domainProvider: (String, @escaping (URLQueryResult) -> Void) -> Void = { bundleId, completion in
        BrowserURLReader.currentDomain(bundleId: bundleId, completion: completion)
    }
    /// 当前前台 App（bundleId + 显示名）。默认走 NSWorkspace。
    var frontmostProvider: () -> (bundleId: String, name: String)? = {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleId = front.bundleIdentifier else { return nil }
        return (bundleId, front.localizedName ?? bundleId)
    }
    /// 系统空闲秒数。默认走 IdleClock。
    var idleProvider: () -> TimeInterval = { IdleClock.secondsSinceLastInput() }
    /// 当前时间。默认 Date()。
    var nowProvider: () -> Date = { Date() }
    var authorizationProvider: (String, @escaping (BrowserPermissionResult) -> Void) -> Void = {
        BrowserURLReader.requestAuthorization(bundleId: $0, completion: $1)
    }
    var runningBrowsersProvider: () -> [String] = {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            .filter { WebGroup.supportsURLReading($0) }.sorted()
    }
    /// 被动使用信号查询（bundleId, 是否含音频）。默认走 PassiveSignal；测试注入确定性结果。
    var passiveSignalProvider: (String, Bool) -> Bool = {
        PassiveSignal.isActive(bundleId: $0, includeAudio: $1)
    }
    var openAutomationSettingsProvider: () -> Void = {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
    var openAccessibilitySettingsProvider: () -> Void = {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    /// 重置本 App 的 TCC「自动化」记录（v0.8.2）。
    /// macOS 对拒绝过的 App 不会再弹授权窗（stays on record as no），静默失败；
    /// tccutil 的 bundle_id 参数是**发起方 client**（本 App），只清自己的记录、无副作用。
    /// 无头测试可替换此注入点，真跑会污染测试机 TCC。
    var tccutilResetProvider: () -> Void = {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/tccutil"),
                             arguments: ["reset", "AppleEvents", "com.darinji.moyutimer"])
    }

    private var idleThreshold: TimeInterval? {
        guard let minutes = UserDefaults.standard.object(forKey: "idleThresholdMinutes") as? Int else { return 300 }
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    /// 统一闲置裁决（§0 三档）：返回应结算到的截止时刻；nil = 继续计时。
    /// isVideoPage：当前（或将开启的）会话是否视频页。ignoringSignal：换上下文时忽略旧信号证据。
    private func idleCutoff(now: Date, isVideoPage: Bool, ignoringSignal: Bool = false) -> Date? {
        guard let idleThreshold else { return nil }
        let idle = idleProvider()
        let lastInput = now.addingTimeInterval(-idle)
        let signalAt = ignoringSignal ? nil : lastSignalAt
        // 阳性信号仍在保鲜期：不按时间判闲置；无输入超过硬上限才截断
        if let signalAt, now.timeIntervalSince(signalAt) <= signalFreshness {
            return idle >= passiveCap ? lastInput.addingTimeInterval(passiveCap) : nil
        }
        let anchor = max(lastInput, signalAt ?? .distantPast)
        // 信号曾出现又消失（暂停/播完/转静音）→ 回到用户阈值，从最后阳性点起算；
        // 从未见过信号 → 视频页放宽 30 分钟，其余按用户阈值
        let threshold = signalAt != nil ? idleThreshold
            : (isVideoPage ? max(idleThreshold, videoIdleThreshold) : idleThreshold)
        return now.timeIntervalSince(anchor) >= threshold ? anchor : nil
    }

    /// 采样被动使用信号：仅合格上下文（前台原生会话 / 前台浏览器上的视频页）。
    private func sampleSignalIfNeeded(now: Date, idle: TimeInterval) {
        guard idleThreshold != nil, let session = open,
              idle >= signalSampleMinIdle,
              now.timeIntervalSince(lastSignalSampleAt) >= signalSampleInterval else { return }
        lastSignalSampleAt = now
        guard let front = frontmostProvider() else { return }
        if session.bundleId != WebGroup.bundleId {
            // 原生会话：仅前台同一 App 的「保持屏幕常亮」信号（音频不算）
            guard session.bundleId == front.bundleId else { return }
            if passiveSignalProvider(session.bundleId, false) { lastSignalAt = now }
        } else if session.isVideoPage, WebGroup.isBrowser(front.bundleId) {
            if passiveSignalProvider(front.bundleId, true) { lastSignalAt = now }
        }
    }

    init(store: Store) {
        self.store = store
        UserDefaults.standard.removeObject(forKey: Self.webRetryPendingKey)   // 上次异常退出可能残留
        observeSystemEvents()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func start() {
        store.recoverOpenSessions()   // 上次异常退出遗留的打开中会话直接结算
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)   // 菜单展开期间也要继续走
        tick()
    }

    /// Manual pause shares the exclusion boundary with lock/sleep so late URL results
    /// cannot reopen a session or bridge the pause gap.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        let wasExcluded = isExcluded
        isPaused = paused
        updateExclusion(wasExcluded: wasExcluded)
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        closeOpenSession(endAt: nowProvider())
    }

    /// 当前打开中的会话（供 UI 实时累加）。
    var liveSession: OpenSession? { open }

    /// 距上次落盘以来新增的毫秒数与有效分类；空闲中返回 nil。
    /// 网页会话按当前域名的分类计（b站→摸鱼、GitHub→工作）。
    func liveDelta() -> (ms: Int, category: AppCategory)? {
        let now = nowProvider()
        guard !isExcluded, let open, idleCutoff(now: now, isVideoPage: open.isVideoPage) == nil else { return nil }
        let delta = nowProvider().timeIntervalSince(open.lastFlush)
        guard delta > 0 else { return nil }
        var category = store.category(ofAppId: open.appId)
        if let domain = open.domain, !domain.isEmpty, let dc = store.domainCategory(domain) {
            category = dc
        }
        return (Int(delta * 1000), category)
    }

    /// 用户打开我们自己的菜单栏 UI 时调用：立刻结算上一段，避免把看统计的时间算成工作时间。
    func suspendForOwnUI() {
        closeOpenSession(endAt: nowProvider())
    }

    /// Request consent for a running browser even while our own popover is frontmost.
    /// Previously denied consent is changed in System Settings; never reset TCC automatically.
    func goAuthorize(bundleId: String? = nil) {
        guard !authorizationInFlight else { return }
        let running = runningBrowsersProvider()
        let front = frontmostProvider()?.bundleId
        let target: String?
        if let bundleId {
            target = running.contains(bundleId) && WebGroup.supportsURLReading(bundleId) ? bundleId : nil
        } else {
            target = [front, mostRecentBrowserBundleId].compactMap { $0 }
                .first { running.contains($0) && WebGroup.supportsURLReading($0) }
                ?? running.first(where: WebGroup.supportsURLReading)
        }
        guard let target else {
            let message = bundleId.flatMap(WebGroup.browserName)
                .map { "请先打开 \($0) 后重试" }
                ?? "请先打开 Safari 或 Chrome 等支持的浏览器"
            UserDefaults.standard.set(message, forKey: Self.webPermissionMessageKey)
            return
        }
        authorizationInFlight = true
        UserDefaults.standard.set(true, forKey: Self.webRetryPendingKey)
        UserDefaults.standard.removeObject(forKey: Self.webPermissionMessageKey)
        authorizationProvider(target) { [weak self] result in
            guard let self else { return }
            self.authorizationInFlight = false
            UserDefaults.standard.set(false, forKey: Self.webRetryPendingKey)
            switch result {
            case .authorized:
                UserDefaults.standard.removeObject(forKey: BrowserURLReader.permissionDeniedKey)
                self.webRetryRequested = true
                self.lastURLQueryAt = .distantPast
            case .denied:
                UserDefaults.standard.set(true, forKey: BrowserURLReader.permissionDeniedKey)
                if WebGroup.usesAccessibility(target) {
                    UserDefaults.standard.set("Firefox 需要辅助功能权限，请在系统设置中允许「摸了个鱼」读取当前网页地址。", forKey: Self.webPermissionMessageKey)
                }
                self.openBrowserPermissionSettings(bundleId: target)
            case .failed:
                UserDefaults.standard.set("授权未完成，请确认浏览器已打开后重试", forKey: Self.webPermissionMessageKey)
            }
        }
    }

    func openBrowserPermissionSettings(bundleId: String? = nil) {
        let running = runningBrowsersProvider().filter(WebGroup.supportsURLReading)
        let target = bundleId ?? [mostRecentBrowserBundleId, running.first].compactMap { $0 }.first(where: running.contains)
        if let target, WebGroup.usesAccessibility(target) { openAccessibilitySettingsProvider() }
        else { openAutomationSettingsProvider() }
    }

    static let webRetryPendingKey = "webRetryPending"
    static let webPermissionMessageKey = "webPermissionMessage"

    /// 「重置授权」（v0.8.2）：清掉 TCC 里旧的拒绝记录 + 本地标记，然后预约重试。
    /// 之后切到浏览器，系统会把本 App 当全新请求方重新弹「自动化」窗。
    func resetAuthorization() {
        tccutilResetProvider()
        UserDefaults.standard.removeObject(forKey: BrowserURLReader.permissionDeniedKey)
        UserDefaults.standard.removeObject(forKey: Self.webPermissionMessageKey)
        UserDefaults.standard.set(true, forKey: Self.webRetryPendingKey)
        webRetryRequested = true
        lastURLQueryAt = .distantPast
    }

    // MARK: 系统事件

    private func observeSystemEvents() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.setSleeping(true) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setSleeping(false)
            self?.setDisplayAsleep(false)   // 系统唤醒必然伴随亮屏
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.setDisplayAsleep(true) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.setDisplayAsleep(false) }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.setScreenLocked(true) }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.setScreenLocked(false) }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main
        ) { [weak self] _ in self?.setScreenSaverActive(true) }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main
        ) { [weak self] _ in self?.setScreenSaverActive(false) }
    }

    /// 进入/退出「锁屏、睡眠」排除状态（计划 3.2）。通知与无头测试都走这里。
    func setSystemExcluded(_ excluded: Bool) {
        let wasExcluded = isExcluded
        isScreenLocked = excluded
        isSleeping = excluded
        updateExclusion(wasExcluded: wasExcluded)
    }

    private func setScreenLocked(_ locked: Bool) {
        let wasExcluded = isExcluded
        isScreenLocked = locked
        updateExclusion(wasExcluded: wasExcluded)
    }

    private func setSleeping(_ sleeping: Bool) {
        let wasExcluded = isExcluded
        isSleeping = sleeping
        updateExclusion(wasExcluded: wasExcluded)
    }

    /// 屏保启停排除（无头测试可直接调用）。
    func setScreenSaverActive(_ active: Bool) {
        let wasExcluded = isExcluded
        isScreenSaverActive = active
        if active { screenSaverSetAt = nowProvider() }
        updateExclusion(wasExcluded: wasExcluded)
    }

    /// 熄屏/亮屏排除（无头测试可直接调用）。
    func setDisplayAsleep(_ asleep: Bool) {
        let wasExcluded = isExcluded
        isDisplayAsleep = asleep
        if asleep { displayAsleepSetAt = nowProvider() }
        updateExclusion(wasExcluded: wasExcluded)
    }

    private func updateExclusion(wasExcluded: Bool) {
        if isExcluded && !wasExcluded {
            webGeneration &+= 1
            webQueryForcePending = false
            closeOpenSession(endAt: nowProvider())
        } else if !isExcluded && wasExcluded {
            lastURLQueryAt = .distantPast
            lastBrowserBundleId = nil
        }
    }

    // MARK: 主循环

    @objc func tick() {
        let now = nowProvider()

        // 屏保/熄屏自愈：标记设置后又有键鼠输入 → 视为误报/提前唤醒，清标记
        if isScreenSaverActive, idleProvider() < now.timeIntervalSince(screenSaverSetAt) {
            setScreenSaverActive(false)
        }
        if isDisplayAsleep, idleProvider() < now.timeIntervalSince(displayAsleepSetAt) {
            setDisplayAsleep(false)
        }

        // 锁屏/睡眠/屏保/熄屏：整段不计。残留会话立即结算；结束后从事件时刻开新段，不桥接
        if isExcluded {
            closeOpenSession(endAt: now)
            return
        }

        let idle = idleProvider()
        sampleSignalIfNeeded(now: now, idle: idle)

        // 空闲裁决（§0 三档）：命中则按截止时刻结算当前会话
        if let current = open, let cutoff = idleCutoff(now: now, isVideoPage: current.isVideoPage) {
            closeOpenSession(endAt: min(cutoff, now))
            return
        }
        // 无会话且处于普通闲置：不重开新段（视频页放宽由 handleDomainResult 的 idleCutoff 裁决）
        if open == nil, let idleThreshold, idle >= idleThreshold { return }

        handleDayRollover(now: now)

        guard let front = frontmostProvider() else {
            if lastBrowserBundleId != nil { webGeneration &+= 1 }
            lastBrowserBundleId = nil
            closeOpenSession(endAt: now)
            return
        }
        let bundleId = front.bundleId

        // 不记录自己（菜单栏 App 被激活时）
        if bundleId == Bundle.main.bundleIdentifier {
            if lastBrowserBundleId != nil { webGeneration &+= 1 }
            lastBrowserBundleId = nil
            closeOpenSession(endAt: now)
            return
        }

        let isWeb = WebGroup.isBrowser(bundleId)
        if isWeb, WebGroup.supportsURLReading(bundleId) {
            mostRecentBrowserBundleId = bundleId
        }
        if let previousBrowser = lastBrowserBundleId,
           !isWeb || previousBrowser != bundleId {
            webGeneration &+= 1
        }
        let targetBundle = isWeb ? WebGroup.bundleId : bundleId
        let targetName = isWeb ? WebGroup.name : front.name

        if let current = open, current.bundleId == targetBundle {
            // 目标未变（App 不变，或都是网页统计组）
            if now.timeIntervalSince(current.lastFlush) >= flushInterval {
                store.flushSession(rowId: current.rowId, endTs: Int(now.timeIntervalSince1970))
                open?.lastFlush = now
            }
            if isWeb {
                // 用户点了「重试/重置授权」后停留在浏览器：本次 tick 自动重查
                var force = lastBrowserBundleId != bundleId
                if webRetryRequested {
                    webRetryRequested = false
                    force = true
                }
                // 换了浏览器（Chrome→Safari）也要立即重查，避免把时间记到旧域名上
                requestDomainIfNeeded(bundleId: bundleId, now: now, force: force)
                lastBrowserBundleId = bundleId
            }
        } else {
            // 目标变了：结算旧会话，开新会话
            closeOpenSession(endAt: now)
            if isWeb {
                // 网页：先查 URL 再开段——拿不到网址就不计时（v0.8 闭环）
                let force = webRetryRequested || lastBrowserBundleId != bundleId
                webRetryRequested = false
                requestDomainIfNeeded(bundleId: bundleId, now: now, force: force)
                lastBrowserBundleId = bundleId
            } else {
                lastBrowserBundleId = nil
                open = store.openSession(bundleId: bundleId, name: targetName,
                                         start: now)
            }
        }

        // 查询超时（授权弹窗挂起 / 浏览器无响应）：主动停止归属，
        // 不把等待时间继续算到旧域名头上；结果回来后从完成时刻重新开段
        if webQueryInFlight && !webQueryExpired
            && now.timeIntervalSince(webQueryStartedAt) >= urlQueryTimeout {
            webQueryExpired = true
            if let current = open, current.bundleId == WebGroup.bundleId {
                closeOpenSession(endAt: max(webQueryStartedAt, current.lastFlush))
            }
        }
    }

    /// 跨天处理：打开中的会话跨越本地零点时按天切分，本 tick 后续逻辑会为当前前台 App 开新会话。
    private func handleDayRollover(now: Date) {
        guard let current = open,
              !DayRange.localCalendar.isDate(current.start, inSameDayAs: now) else { return }
        let midnightTs = Int(DayRange.localCalendar.startOfDay(for: now).timeIntervalSince1970)
        store.closeSession(rowId: current.rowId, endTs: midnightTs)
        open = nil
        // 网页会话：本 tick 立即重查网址，零点后无缝续段（否则要等满查询间隔）
        if current.bundleId == WebGroup.bundleId { lastURLQueryAt = .distantPast }
    }

    private func closeOpenSession(endAt: Date) {
        guard let current = open else { return }
        let end = max(endAt, current.start)   // 防御时钟回跳导致的负时长
        store.closeSession(rowId: current.rowId, endTs: Int(end.timeIntervalSince1970))
        open = nil
        // 换上下文：旧信号证据不得带入新会话（跨天切分除外——同一上下文延续）
        lastSignalAt = nil
        lastSignalSampleAt = .distantPast
    }

    // MARK: 浏览器 URL 查询

    private func requestDomainIfNeeded(bundleId: String, now: Date, force: Bool) {
        if webQueryInFlight {
            // 串行化期间来的强制请求（典型：Chrome→Safari）先记账，结果回来后立即补发
            if force { webQueryForcePending = true }
            return
        }
        guard force || now.timeIntervalSince(lastURLQueryAt) >= urlQueryInterval else { return }
        issueDomainQuery(bundleId: bundleId, now: now)
    }

    private func issueDomainQuery(bundleId: String, now: Date) {
        lastURLQueryAt = now
        webQueryInFlight = true
        webQueryStartedAt = now
        webQueryExpired = false
        let generation = webGeneration
        domainProvider(bundleId) { [weak self] result in
            self?.handleDomainResult(result, bundleId: bundleId,
                                     startedAt: now, generation: generation)
        }
    }

    /// URL 查询回来（规则见文件头）：
    /// - 前台必须仍是查询时那个浏览器，否则丢弃结果
    /// - 读到网址：域名没变 → 不动；变了 → 以「查询发起时刻」为界换段（首尾相接不重叠）
    /// - 读不到：立即停计（不开新段）；授权被拒时置标记引导用户
    /// - 超时后迟到的结果：从「完成时刻」开段，不补计等待时间
    private func handleDomainResult(_ result: URLQueryResult, bundleId: String,
                                    startedAt: Date, generation: UInt64) {
        // .pending = 读者仍有查询在进行：保持 inFlight，等它的真实结果
        if case .pending = result { return }

        webQueryInFlight = false
        let expired = webQueryExpired
        webQueryExpired = false
        let completedAt = nowProvider()

        defer {
            // 被串行化跳过的强制查询（切浏览器）立即补发，避免新浏览器最多白等 5s
            if webQueryForcePending && !isExcluded {
                webQueryForcePending = false
                if let front = frontmostProvider(), WebGroup.isBrowser(front.bundleId) {
                    issueDomainQuery(bundleId: front.bundleId, now: nowProvider())
                }
            }
        }

        guard !isExcluded, generation == webGeneration else { return }

        // 查询期间前台可能切走、或换了浏览器：只有仍是同一个浏览器才采纳
        guard let front = frontmostProvider(),
              WebGroup.isBrowser(front.bundleId), front.bundleId == bundleId else {
            if let current = open, current.bundleId == WebGroup.bundleId {
                closeOpenSession(endAt: max(startedAt, current.lastFlush))
            }
            return
        }

        // A completed scheduled retry must release the banner and its disabled controls.
        if !authorizationInFlight && UserDefaults.standard.bool(forKey: Self.webRetryPendingKey) {
            UserDefaults.standard.set(false, forKey: Self.webRetryPendingKey)
        }

        switch result {
        case .domain(let domain), .videoPage(let domain):
            let isVideoPage: Bool
            if case .videoPage = result { isVideoPage = true } else { isVideoPage = false }
            let sameContext = open?.bundleId == WebGroup.bundleId
                && open?.domain == domain && open?.isVideoPage == isVideoPage
            // 换上下文时按新页面类型判闲置且忽略旧信号证据；
            // open == nil（如跨天续段）沿用现有信号——同一上下文延续
            if !sameContext,
               idleCutoff(now: completedAt, isVideoPage: isVideoPage, ignoringSignal: open != nil) != nil {
                if let current = open, current.bundleId == WebGroup.bundleId {
                    closeOpenSession(endAt: max(startedAt, current.lastFlush))
                }
                return
            }
            // 读到网址：授权正常，清除「未授权」标记（Popover 横幅随之消失）
            UserDefaults.standard.removeObject(forKey: BrowserURLReader.permissionDeniedKey)
            UserDefaults.standard.removeObject(forKey: Self.webPermissionMessageKey)
            // 超时的查询不补计等待时间：从完成时刻开段
            let startAt = expired ? completedAt : startedAt
            if let current = open, current.bundleId == WebGroup.bundleId {
                if current.domain == domain && current.isVideoPage == isVideoPage { return }
                closeOpenSession(endAt: max(startAt, current.lastFlush))
            } else if open != nil {
                closeOpenSession(endAt: startAt)         // 异常路径：先结算非网页会话
            }
            open = store.openSession(bundleId: WebGroup.bundleId, name: WebGroup.name,
                                     domain: domain, start: startAt)
            open?.isVideoPage = isVideoPage

        case .denied:
            // 拿不到网址：停计（进行中的网页段在查询发起时刻结算）
            if let current = open, current.bundleId == WebGroup.bundleId {
                closeOpenSession(endAt: max(startedAt, current.lastFlush))
            }
            // 引导用户放行「自动化」权限
            UserDefaults.standard.set(true, forKey: BrowserURLReader.permissionDeniedKey)

        case .failed:
            if let current = open, current.bundleId == WebGroup.bundleId {
                closeOpenSession(endAt: max(startedAt, current.lastFlush))
            }

        case .pending:
            break
        }
    }
}
