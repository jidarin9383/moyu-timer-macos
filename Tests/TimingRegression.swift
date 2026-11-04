import Foundation

@main
struct TimingRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoyuTimingRegression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!

        func store(_ name: String) throws -> Store {
            setenv("MOYU_DB_DIR", root.appendingPathComponent(name).path, 1)
            return try Store()
        }

        func total(_ store: Store, from: Date, to: Date) -> Int {
            store.categoryTotals(from: Int(from.timeIntervalSince1970),
                                 to: Int(to.timeIntervalSince1970)).values.reduce(0, +)
        }

        func expect(_ actual: Int, _ expected: Int, _ label: String) {
            precondition(actual == expected, "\(label): expected \(expected), got \(actual)")
            print("PASS \(label)")
        }

        let idleSettingKey = "idleThresholdMinutes"
        let previousIdleSetting = UserDefaults.standard.object(forKey: idleSettingKey)
        defer {
            if let previousIdleSetting { UserDefaults.standard.set(previousIdleSetting, forKey: idleSettingKey) }
            else { UserDefaults.standard.removeObject(forKey: idleSettingKey) }
        }

        do {
            UserDefaults.standard.set(0, forKey: idleSettingKey)
            let db = try store("idle-disabled")
            let tracker = UsageTracker(store: db)
            tracker.passiveSignalProvider = { _, _ in false }
            var now = base
            tracker.nowProvider = { now }
            tracker.idleProvider = { 600 }
            tracker.frontmostProvider = { ("com.example.A", "A") }
            tracker.tick()
            now = base.addingTimeInterval(60)
            tracker.suspendForOwnUI()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 60_000,
                   "zero-minute setting disables idle exclusion")
        }

        do {
            UserDefaults.standard.set(5, forKey: idleSettingKey)
            let videoURLs = [
                "https://www.miguvideo.com/p/live/120000584221",
                "https://www.bilibili.com/video/BV123",
                "https://live.bilibili.com/12345",
                "https://www.youtube.com/watch?v=abc",
                "https://www.youtube.com/shorts/abc",
                "https://www.douyin.com/video/123",
                "https://www.kuaishou.com/short-video/123",
                "https://www.iqiyi.com/v_abc.html",
                "https://v.qq.com/x/cover/abc/def.html",
                "https://www.youku.com/v_show/id_abc.html",
                "https://www.netflix.com/watch/123",
                "https://www.douyu.com/12345",
                "https://www.twitch.tv/channel"
            ]
            let ordinaryURLs = [
                "https://www.miguvideo.com/p/video/120000584221",
                "https://miguvideo.com.evil.test/p/live/120000584221",
                "https://www.youtube.com/watch",
                "https://www.bilibili.com/",
                "https://www.douyin.com/user/123",
                "https://www.netflix.com/browse",
                "https://www.huya.com/category",
                "https://www.douyu.com/directory",
                "https://www.twitch.tv/directory",
                "https://www.twitch.tv/"
            ]
            for address in videoURLs { precondition(VideoPageRules.matches(URL(string: address)!), address) }
            for address in ordinaryURLs { precondition(!VideoPageRules.matches(URL(string: address)!), address) }
            let db = try store("live-idle")
            let tracker = UsageTracker(store: db)
            tracker.passiveSignalProvider = { _, _ in false }
            var now = base
            var idleSeconds: TimeInterval = 0
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(.videoPage("miguvideo.com")) }
            tracker.tick()
            now = base.addingTimeInterval(600)
            idleSeconds = 600
            tracker.tick()
            precondition(tracker.liveSession != nil, "live stream stopped during idle time")
            now = now.addingTimeInterval(1)
            precondition(tracker.liveDelta()?.ms == 1_000, "video page does not show live idle time")
            tracker.setSystemExcluded(true)
            now = now.addingTimeInterval(60)
            tracker.tick()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 601_000,
                   "recognized video page counts idle time but stops at lock")
        }

        do {
            let db = try store("video-to-ordinary")
            let tracker = UsageTracker(store: db)
            tracker.passiveSignalProvider = { _, _ in false }
            var now = base
            var idleSeconds: TimeInterval = 0
            var result = URLQueryResult.videoPage("miguvideo.com")
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(result) }
            tracker.tick()
            now = base.addingTimeInterval(10)
            result = .domain("miguvideo.com")
            tracker.tick()
            now = base.addingTimeInterval(310)
            idleSeconds = 300
            tracker.tick()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 10_000,
                   "same-domain nonvideo page restores idle exclusion")
        }

        do {
            let db = try store("ordinary-web-idle")
            let tracker = UsageTracker(store: db)
            tracker.passiveSignalProvider = { _, _ in false }
            var now = base
            var idleSeconds: TimeInterval = 0
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(.domain("github.com")) }
            tracker.tick()
            now = base.addingTimeInterval(600)
            idleSeconds = 600
            tracker.tick()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 0,
                   "ordinary websites still exclude idle time")
        }

        do {
            let db = try store("lock-gap")
            let tracker = UsageTracker(store: db)
            tracker.passiveSignalProvider = { _, _ in false }
            var now = base
            tracker.nowProvider = { now }
            tracker.idleProvider = { 0 }
            tracker.frontmostProvider = { ("com.example.A", "A") }
            tracker.tick()
            now = base.addingTimeInterval(10)
            tracker.setSystemExcluded(true)
            now = base.addingTimeInterval(30)
            tracker.setSystemExcluded(false)
            tracker.tick()
            now = base.addingTimeInterval(40)
            tracker.suspendForOwnUI()
            expect(total(db, from: base.addingTimeInterval(-1),
                         to: base.addingTimeInterval(100)), 20_000,
                   "lock gap is excluded")
        }

        do {
            let db = try store("locked-callback")
            let tracker = UsageTracker(store: db)
            tracker.passiveSignalProvider = { _, _ in false }
            var now = base
            var completion: ((URLQueryResult) -> Void)?
            tracker.nowProvider = { now }
            tracker.idleProvider = { 0 }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, callback in completion = callback }
            tracker.tick()
            now = base.addingTimeInterval(1)
            tracker.setSystemExcluded(true)
            now = base.addingTimeInterval(2)
            completion?(.domain("github.com"))
            precondition(tracker.liveSession == nil, "locked callback reopened a session")
            now = base.addingTimeInterval(5)
            tracker.tick()
            expect(total(db, from: base.addingTimeInterval(-1),
                         to: base.addingTimeInterval(100)), 0,
                   "locked URL callback is discarded")
        }

        do {
            let db = try store("callback-after-unlock")
            let tracker = UsageTracker(store: db)
            tracker.passiveSignalProvider = { _, _ in false }
            var now = base
            var callbacks: [(URLQueryResult) -> Void] = []
            tracker.nowProvider = { now }
            tracker.idleProvider = { 0 }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, callback in callbacks.append(callback) }
            tracker.tick()
            now = base.addingTimeInterval(1)
            tracker.setSystemExcluded(true)
            now = base.addingTimeInterval(5)
            tracker.setSystemExcluded(false)
            callbacks[0](.domain("github.com"))
            precondition(tracker.liveSession == nil, "old callback reopened a session after unlock")
            tracker.tick()
            precondition(callbacks.count == 2, "unlock did not request a fresh URL")
            callbacks[1](.domain("github.com"))
            now = base.addingTimeInterval(10)
            tracker.suspendForOwnUI()
            expect(total(db, from: base.addingTimeInterval(-1),
                         to: base.addingTimeInterval(100)), 5_000,
                   "fresh URL after unlock starts at the new query")
        }

        do {
            let db = try store("midnight")
            let midnight = calendar.date(byAdding: .day, value: 1,
                                         to: calendar.startOfDay(for: base))!
            let start = midnight.addingTimeInterval(-1)
            let session = db.openSession(bundleId: "com.example.A", name: "A", start: start)
            db.closeSession(rowId: session.rowId,
                            endTs: Int(midnight.addingTimeInterval(300).timeIntervalSince1970))
            expect(total(db, from: calendar.startOfDay(for: start), to: midnight), 1_000,
                   "last second belongs to previous day")
            expect(total(db, from: midnight,
                         to: calendar.date(byAdding: .day, value: 1, to: midnight)!), 300_000,
                   "post-midnight time belongs to new day")
            let dailySum = db.dailyBreakdown(
                from: Int(calendar.startOfDay(for: start).timeIntervalSince1970),
                to: Int(calendar.date(byAdding: .day, value: 1, to: midnight)!.timeIntervalSince1970))
                .reduce(0) { $0 + $1.ms }
            expect(dailySum, 301_000, "daily chart reconciles with period total")
        }

        do {
            let saturday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17))!
            let week = DayRange.week(saturday)
            let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
            expect(week.start, Int(monday.timeIntervalSince1970), "week starts on Monday")
            expect(week.end, Int(calendar.date(byAdding: .day, value: 7, to: monday)!.timeIntervalSince1970),
                   "week contains seven calendar days")

            for (year, month, days) in [(2023, 2, 28), (2024, 2, 29), (2026, 4, 30), (2026, 10, 31)] {
                let middle = calendar.date(from: DateComponents(year: year, month: month, day: 15))!
                let range = DayRange.month(middle)
                let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
                let end = calendar.date(byAdding: .day, value: days, to: start)!
                expect(range.start, Int(start.timeIntervalSince1970), "month \(year)-\(month) start")
                expect(range.end, Int(end.timeIntervalSince1970), "month \(year)-\(month) end")
            }
        }

        // §0 三档裁决：视频页无信号 → 30 分钟固定阈值，闲置确认后回吐到最后输入
        do {
            UserDefaults.standard.set(5, forKey: idleSettingKey)
            let db = try store("video-no-signal-30min")
            let tracker = UsageTracker(store: db)
            tracker.passiveSignalProvider = { _, _ in false }
            var now = base
            var idleSeconds: TimeInterval = 0
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(.videoPage("miguvideo.com")) }
            tracker.tick()
            now = base.addingTimeInterval(1899)
            idleSeconds = 1799                      // 输入停在 base+100
            tracker.tick()
            precondition(tracker.liveSession != nil, "video page closed before the 30-minute idle tier")
            now = base.addingTimeInterval(1900)
            idleSeconds = 1800
            tracker.tick()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 100_000,
                   "video page without signal loses idle back to last input")
        }

        // 信号保护：阳性期间不受闲置限制；信号消失后回到 30 分钟档并在最后阳性点截断
        do {
            let db = try store("video-signal-protected")
            let tracker = UsageTracker(store: db)
            var now = base
            var idleSeconds: TimeInterval = 0
            var signal = false
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(.videoPage("miguvideo.com")) }
            tracker.passiveSignalProvider = { _, includeAudio in
                precondition(includeAudio, "video page must sample browser audio")
                return signal
            }
            tracker.tick()
            signal = true
            now = base.addingTimeInterval(50)
            idleSeconds = 50
            tracker.tick()                          // 首次采样 → 阳性
            now = base.addingTimeInterval(7200)
            idleSeconds = 7200
            tracker.tick()                          // 重采样 → lastSignalAt = base+7200
            precondition(tracker.liveSession != nil, "signal-protected session closed during idle")
            now = base.addingTimeInterval(7201)
            idleSeconds = 7201
            precondition(tracker.liveDelta()?.ms == 1_000, "protected session lacks live delta")
            signal = false
            now = base.addingTimeInterval(7202)
            idleSeconds = 7202
            tracker.tick()                          // 保鲜期内仍开
            precondition(tracker.liveSession != nil, "session closed inside signal freshness window")
            now = base.addingTimeInterval(7499)
            idleSeconds = 7499
            tracker.tick()                          // 距最后阳性 299s < 用户阈值
            precondition(tracker.liveSession != nil, "session closed before user threshold after signal loss")
            now = base.addingTimeInterval(7500)
            idleSeconds = 7500
            tracker.tick()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 7_200_000,
                   "signal loss cuts video page at last positive after user threshold")
        }

        // 信号消失后按用户阈值：10 分钟阈值下截断点不变，确认时刻顺延
        do {
            let priorThreshold = UserDefaults.standard.object(forKey: idleSettingKey)
            UserDefaults.standard.set(10, forKey: idleSettingKey)
            defer {
                if let priorThreshold { UserDefaults.standard.set(priorThreshold, forKey: idleSettingKey) }
                else { UserDefaults.standard.removeObject(forKey: idleSettingKey) }
            }
            let db = try store("signal-loss-10min")
            let tracker = UsageTracker(store: db)
            var now = base
            var idleSeconds: TimeInterval = 0
            var signal = false
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(.videoPage("miguvideo.com")) }
            tracker.passiveSignalProvider = { _, _ in signal }
            tracker.tick()
            signal = true
            now = base.addingTimeInterval(50)
            idleSeconds = 50
            tracker.tick()
            now = base.addingTimeInterval(7200)
            idleSeconds = 7200
            tracker.tick()                          // lastSignalAt = base+7200
            signal = false
            now = base.addingTimeInterval(7799)
            idleSeconds = 7799
            tracker.tick()                          // 距最后阳性 599s < 600s 阈值
            precondition(tracker.liveSession != nil, "session closed before 10-minute threshold after signal loss")
            now = base.addingTimeInterval(7800)
            idleSeconds = 7800
            tracker.tick()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 7_200_000,
                   "signal loss with 10-minute threshold still cuts at last positive")
        }

        // 硬上限：信号持续阳性但无输入满 3 小时 → 截断在最后输入 + 3h
        do {
            let db = try store("signal-cap")
            let tracker = UsageTracker(store: db)
            var now = base
            var idleSeconds: TimeInterval = 0
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(.videoPage("miguvideo.com")) }
            tracker.passiveSignalProvider = { _, _ in true }
            tracker.tick()
            now = base.addingTimeInterval(50)
            idleSeconds = 50
            tracker.tick()
            now = base.addingTimeInterval(10_799)
            idleSeconds = 10_799
            tracker.tick()
            precondition(tracker.liveSession != nil, "signal-protected session closed before the 3h cap")
            now = base.addingTimeInterval(10_801)
            idleSeconds = 10_801
            tracker.tick()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 10_800_000,
                   "signal-protected counting hard-caps at three hours without input")
        }

        // 普通网页：从不采样信号；阈值一到按最后输入截断
        do {
            let db = try store("ordinary-web-no-signal")
            let tracker = UsageTracker(store: db)
            var now = base
            var idleSeconds: TimeInterval = 0
            var calls = 0
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(.domain("github.com")) }
            tracker.passiveSignalProvider = { _, _ in calls += 1; return true }
            tracker.tick()
            now = base.addingTimeInterval(300)
            idleSeconds = 300
            tracker.tick()
            precondition(calls == 0, "ordinary web page must never sample passive signals")
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 0,
                   "ordinary websites exclude idle even when a signal would be positive")
        }

        // 原生 App：仅看「保持屏幕常亮」（音频不算）；信号消失后按普通阈值从最后阳性点截断
        do {
            let db = try store("native-app-signal")
            let tracker = UsageTracker(store: db)
            var now = base
            var idleSeconds: TimeInterval = 0
            var signal = false
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("org.videolan.vlc", "VLC") }
            tracker.passiveSignalProvider = { bundleId, includeAudio in
                precondition(bundleId == "org.videolan.vlc", "native signal sampled wrong bundle")
                precondition(!includeAudio, "native app must not sample browser audio")
                return signal
            }
            tracker.tick()
            signal = true
            now = base.addingTimeInterval(50)
            idleSeconds = 50
            tracker.tick()
            now = base.addingTimeInterval(1000)
            idleSeconds = 1000
            tracker.tick()                          // 采样 → 阳性 → 保鲜
            precondition(tracker.liveSession != nil, "native app with display signal closed during idle")
            signal = false
            now = base.addingTimeInterval(1300)
            idleSeconds = 1300
            tracker.tick()                          // 距最后阳性 300s，普通阈值已到 → 截于阳性点
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 1_000_000,
                   "native app without video-page flag cuts at signal loss after ordinary threshold")
        }

        // 上下文切换不继承旧信号：migu（有信号史）→ bilibili（新域名），闲置已满 30min → 不开新段
        do {
            let db = try store("context-reset")
            let tracker = UsageTracker(store: db)
            var now = base
            var idleSeconds: TimeInterval = 0
            var signal = false
            var callbacks: [(URLQueryResult) -> Void] = []
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, callback in callbacks.append(callback) }
            tracker.passiveSignalProvider = { _, _ in signal }
            tracker.tick()
            callbacks[0](.videoPage("miguvideo.com"))
            signal = true
            now = base.addingTimeInterval(50)
            idleSeconds = 50
            tracker.tick()                          // 采样 → 阳性；同时发出第二次 URL 查询
            precondition(callbacks.count == 2, "follow-up URL query was not issued")
            signal = false
            now = base.addingTimeInterval(1900)
            idleSeconds = 1900                      // 旧信号已过期 → 按 30min 档结算 migu 段
            tracker.tick()
            precondition(tracker.liveSession == nil, "expired signal kept the old video session open")
            callbacks[1](.videoPage("bilibili.com")) // 新上下文：旧阳性证据不得继承 → 闲置 → 拒开
            precondition(tracker.liveSession == nil, "new video page inherited stale signal evidence")
            now = base.addingTimeInterval(1901)
            idleSeconds = 1901
            tracker.tick()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 50_000,
                   "context switch drops old signal and keeps only protected time")
        }

        // 熄屏：与锁屏同级排除；标记后若检测到新输入则自愈开新段
        do {
            let db = try store("display-sleep")
            let tracker = UsageTracker(store: db)
            tracker.passiveSignalProvider = { _, _ in false }
            var now = base
            var idleSeconds: TimeInterval = 0
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.example.A", "A") }
            tracker.tick()
            now = base.addingTimeInterval(100)
            tracker.setDisplayAsleep(true)          // 熄屏 → 会话在标记时刻结算
            now = base.addingTimeInterval(200)
            idleSeconds = 200
            tracker.tick()                          // 无新输入 → 维持排除
            precondition(tracker.liveSession == nil, "display sleep did not close the session")
            now = base.addingTimeInterval(300)
            idleSeconds = 1                         // 标记后出现输入 → 自愈并开新段
            tracker.tick()
            precondition(tracker.liveSession != nil, "input after display-sleep flag did not recover")
            now = base.addingTimeInterval(400)
            tracker.suspendForOwnUI()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 200_000,
                   "display sleep excludes its span and recovers on input")
        }

        // 屏保：同熄屏，事件来自 com.apple.screensaver.didstart/didstop
        do {
            let db = try store("screensaver")
            let tracker = UsageTracker(store: db)
            tracker.passiveSignalProvider = { _, _ in false }
            var now = base
            var idleSeconds: TimeInterval = 0
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.example.A", "A") }
            tracker.tick()
            now = base.addingTimeInterval(100)
            tracker.setScreenSaverActive(true)
            now = base.addingTimeInterval(200)
            idleSeconds = 200
            tracker.tick()
            precondition(tracker.liveSession == nil, "screensaver did not close the session")
            now = base.addingTimeInterval(300)
            idleSeconds = 1
            tracker.tick()
            precondition(tracker.liveSession != nil, "input after screensaver flag did not recover")
            now = base.addingTimeInterval(400)
            tracker.suspendForOwnUI()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 200_000,
                   "screensaver excludes its span and recovers on input")
        }

        // 全局阈值 0：闲置判定整体关闭，视频页照常计（信号采样也随之关闭）
        do {
            UserDefaults.standard.set(0, forKey: idleSettingKey)
            let db = try store("video-idle-disabled")
            let tracker = UsageTracker(store: db)
            var now = base
            var idleSeconds: TimeInterval = 0
            var calls = 0
            tracker.nowProvider = { now }
            tracker.idleProvider = { idleSeconds }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(.videoPage("miguvideo.com")) }
            tracker.passiveSignalProvider = { _, _ in calls += 1; return false }
            tracker.tick()
            now = base.addingTimeInterval(5000)
            idleSeconds = 5000
            tracker.tick()
            precondition(tracker.liveSession != nil, "disabled idle judgment closed a video page")
            precondition(calls == 0, "signal sampled while idle judgment is disabled")
            tracker.suspendForOwnUI()
            expect(total(db, from: base.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 5_000_000,
                   "zero-minute threshold keeps counting a video page through long idle")
        }

        // §0 跨天续段（有信号）：零点切分后同 tick 重查网址并按原信号证据开新段
        do {
            UserDefaults.standard.set(5, forKey: idleSettingKey)
            let db = try store("midnight-signal-continues")
            let tracker = UsageTracker(store: db)
            let midnight = calendar.date(byAdding: .day, value: 1,
                                         to: calendar.startOfDay(for: base))!
            let start = midnight.addingTimeInterval(-600)
            var now = start
            tracker.nowProvider = { now }
            tracker.idleProvider = { now.timeIntervalSince(start) }   // 输入只发生在开始时刻
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(.videoPage("miguvideo.com")) }
            tracker.passiveSignalProvider = { _, _ in true }
            for offset in stride(from: 0, through: 1800, by: 2) {
                now = start.addingTimeInterval(TimeInterval(offset))
                tracker.tick()
            }
            precondition(tracker.liveSession != nil, "signal-protected video session did not survive midnight")
            tracker.suspendForOwnUI()
            expect(total(db, from: start.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 1_800_000,
                   "signal-protected video page counts seamlessly across local midnight")
        }

        // §0 跨天续段（无信号）：闲置未满 30 分钟档 → 零点后续开同上下文
        do {
            let db = try store("midnight-nosignal-continues")
            let tracker = UsageTracker(store: db)
            let midnight = calendar.date(byAdding: .day, value: 1,
                                         to: calendar.startOfDay(for: base))!
            let start = midnight.addingTimeInterval(-600)
            var now = start
            tracker.nowProvider = { now }
            tracker.idleProvider = { now.timeIntervalSince(start) }
            tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
            tracker.domainProvider = { _, completion in completion(.videoPage("miguvideo.com")) }
            tracker.passiveSignalProvider = { _, _ in false }
            for offset in stride(from: 0, through: 900, by: 2) {
                now = start.addingTimeInterval(TimeInterval(offset))
                tracker.tick()
            }
            precondition(tracker.liveSession != nil, "video session inside the 30-minute tier did not survive midnight")
            tracker.suspendForOwnUI()
            expect(total(db, from: start.addingTimeInterval(-1), to: now.addingTimeInterval(1)), 900_000,
                   "video page inside the 30-minute tier counts seamlessly across local midnight")
        }
    }
}
