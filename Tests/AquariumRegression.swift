import Cocoa

@main
struct AquariumRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoyuAquarium-\(UUID())")
        setenv("MOYU_DB_DIR", directory.path, 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store()
        var failures = 0
        func check(_ value: Bool, _ description: String) {
            print("\(value ? "PASS" : "FAIL") \(description)")
            if !value { failures += 1 }
        }
        var now = Date(timeIntervalSince1970: 1_792_208_000)
        let tracker = UsageTracker(store: store)
        tracker.nowProvider = { now }
        tracker.idleProvider = { 0 }
        tracker.passiveSignalProvider = { _, _ in false }
        tracker.frontmostProvider = { ("com.apple.dt.Xcode", "Xcode") }
        tracker.tick()
        now.addTimeInterval(10)
        tracker.setPaused(true)
        check(tracker.isPaused && tracker.liveSession == nil, "manual pause closes the active session")
        now.addTimeInterval(600)
        tracker.tick()
        check(tracker.liveSession == nil && tracker.liveDelta() == nil, "paused ticks never reopen sessions")
        tracker.setPaused(false)
        tracker.tick()
        now.addTimeInterval(5)
        tracker.shutdown()
        let range = DayRange.day(now)
        check(store.categoryTotals(from: range.start, to: range.end)[.work] == 15_000,
              "resume excludes the entire pause gap")

        var callback: ((URLQueryResult) -> Void)?
        tracker.frontmostProvider = { ("com.google.Chrome", "Chrome") }
        tracker.domainProvider = { _, reply in callback = reply }
        tracker.tick()
        tracker.setPaused(true)
        callback?(.domain("github.com"))
        check(tracker.liveSession == nil, "late browser callback cannot reopen a paused session")
        tracker.setPaused(false)
        callback = nil
        tracker.tick()
        check(callback != nil, "resume issues a fresh browser query")
        callback?(.domain("github.com"))
        check(tracker.liveSession?.domain == "github.com", "fresh browser query resumes tracking")
        tracker.shutdown()

        tracker.setPaused(true)
        tracker.setSystemExcluded(true)
        tracker.setPaused(false)
        tracker.tick()
        check(tracker.liveSession == nil, "manual resume cannot bypass a screen-lock exclusion")
        tracker.setSystemExcluded(false)
        tracker.shutdown()

        let legacyDate = DayRange.localCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let legacy = store.openSession(bundleId: WebGroup.bundleId, name: WebGroup.name,
                                       domain: "(历史浏览)", start: legacyDate)
        store.closeSession(rowId: legacy.rowId, endTs: Int(legacyDate.timeIntervalSince1970) + 600)
        let legacyRange = DayRange.day(legacyDate)
        check(store.appUsage(from: legacyRange.start, to: legacyRange.end).isEmpty
              && store.categoryTotals(from: legacyRange.start, to: legacyRange.end).values.reduce(0, +) == 0,
              "uncounted legacy browsing never exposes a misleading group category menu")
        let known = store.openSession(bundleId: WebGroup.bundleId, name: WebGroup.name,
                                      domain: "bilibili.com", start: legacyDate.addingTimeInterval(600))
        store.closeSession(rowId: known.rowId, endTs: Int(legacyDate.timeIntervalSince1970) + 1_200)
        let parents = store.appUsage(from: legacyRange.start, to: legacyRange.end)
        let domains = store.domainUsage(appId: known.appId, from: legacyRange.start, to: legacyRange.end)
        check(parents.reduce(0) { $0 + $1.ms } == domains.reduce(0) { $0 + $1.ms },
              "web parent menu covers exactly the countable domain total")

        let empty = AquariumSummary(workMs: 0, slackMs: 0)
        check(empty.rate == nil, "no counted time has an undefined leisure rate")
        let summary = AquariumSummary(workMs: 198 * 60_000, slackMs: 92 * 60_000)
        check(summary.rate == 32 && summary.totalMs == 290 * 60_000, "summary uses work plus leisure denominator")
        check(AquariumWeekScale(maxMinutes: 420).maximumHours == 8, "seven-hour day fits an eight-hour scale")
        check(AquariumWeekScale(maxMinutes: 0).maximumHours > 0, "empty week has a safe nonzero scale")
        check(AquariumWeekScale(maxMinutes: 1_440).maximumHours >= 24, "long sessions are never truncated by the chart scale")
        check(AquariumHeat.level(rate: 0.20) == 0 && AquariumHeat.level(rate: 0.35) == 1
              && AquariumHeat.level(rate: 0.5) == 2 && AquariumHeat.level(rate: 0.51) == 3,
              "heat bands follow the OpenDesign thresholds")

        check(FishMood(rate: nil) == .waiting && FishMood(rate: 20) == .calm && FishMood(rate: 35) == .normal
              && FishMood(rate: 50) == .playful && FishMood(rate: 51) == .wild,
              "fish moods follow the leisure-rate phrase bands")
        let moods: [FishMood] = [.calm, .normal, .playful, .wild]
        check(zip(moods, moods.dropFirst()).allSatisfy { $0.speed < $1.speed && $0.tailHz < $1.tailHz },
              "higher leisure rates swim and wag faster")

        func simulate(_ brain: FishBrain, seconds: Double, mood: FishMood, asleep: Bool = false,
                      every: (FishBrain) -> Void = { _ in }) {
            let start = brain.time
            var clock = 1_000 + start
            brain.advance(to: clock, mood: mood, asleep: asleep)
            while brain.time - start < seconds {
                clock += 1.0 / 30
                brain.advance(to: clock, mood: mood, asleep: asleep)
                every(brain)
            }
        }

        let roamer = FishBrain(seed: 7)
        var minX = Double.infinity, maxX = -Double.infinity, minTail = 0.0, maxTail = 0.0, finite = true
        simulate(roamer, seconds: 60, mood: .normal) { brain in
            let pose = brain.pose
            minX = min(minX, pose.position.x); maxX = max(maxX, pose.position.x)
            minTail = min(minTail, pose.tailAngle); maxTail = max(maxTail, pose.tailAngle)
            finite = finite && pose.position.x.isFinite && pose.position.y.isFinite && pose.rotation.isFinite
        }
        let area = roamer.swimArea
        check(finite && minX >= area.minX - 12 && maxX <= area.maxX + 12,
              "roaming fish stays clear of the leisure-rate text")
        check(maxX - minX > 50, "fish roams across the tank instead of hovering in place")
        check(maxTail - minTail > 15, "tail visibly wags while swimming")
        check(!roamer.bubbles.isEmpty || !roamer.ripples.isEmpty, "swimming fish blows bubbles")

        let calm = FishBrain(seed: 3)
        var calmBreach = false
        simulate(calm, seconds: 30, mood: .calm) { calmBreach = calmBreach || $0.pose.position.y < FishBrain.surfaceY + 10 }
        let wild = FishBrain(seed: 3)
        var wildBreach = false, splashed = false
        simulate(wild, seconds: 30, mood: .wild) {
            wildBreach = wildBreach || $0.pose.position.y < FishBrain.surfaceY + 10
            splashed = splashed || !$0.drops.isEmpty
        }
        check(!calmBreach && wildBreach && splashed, "only the wildest mood leaps out with a splash")

        let sleeper = FishBrain(seed: 5)
        simulate(sleeper, seconds: 10, mood: .normal, asleep: true)
        check(sleeper.pose.asleep && sleeper.pose.position.y > 60 && !sleeper.snoozes.isEmpty,
              "paused fish sinks to the bottom and snoozes")
        check(sleeper.tap(at: sleeper.pose.position) == .nudged && sleeper.pellets.isEmpty,
              "tapping a sleeping fish only nudges it awake briefly")
        check(sleeper.tap(at: CGPoint(x: 230, y: 30)) == .ignored, "sleeping fish is not fed")

        let startled = FishBrain(seed: 11)
        simulate(startled, seconds: 2, mood: .calm)
        let before = startled.pose.position, bubblesBefore = startled.bubbles.count
        check(startled.tap(at: before) == .startled && startled.bubbles.count >= bubblesBefore + 7,
              "tapping the fish startles it with a burst of bubbles")
        simulate(startled, seconds: 0.5, mood: .calm)
        check(startled.pose.eyeOpen > 1 && hypot(startled.pose.position.x - before.x, startled.pose.position.y - before.y) > 12,
              "startled fish dashes away wide-eyed")

        let hungry = FishBrain(seed: 13)
        simulate(hungry, seconds: 1, mood: .normal)
        check(hungry.tap(at: CGPoint(x: 20, y: 40)) == .ignored, "taps on the text area never drop food")
        check(hungry.tap(at: CGPoint(x: 200, y: 50)) == .fed && hungry.pellets.count == 1, "tapping water drops a pellet")
        simulate(hungry, seconds: 12, mood: .normal)
        check(hungry.pellets.isEmpty, "fish swims over and eats the pellet")

        let curious = FishBrain(seed: 17)
        simulate(curious, seconds: 1, mood: .normal)
        curious.pointer = CGPoint(x: 290, y: 14)
        simulate(curious, seconds: 4, mood: .normal)
        let gap = hypot(curious.pose.position.x - 290, curious.pose.position.y - 14)
        check(gap < 50 && curious.pose.pupil.dy < 0, "fish swims toward and looks at the hovering pointer")

        let frozen = FishBrain(seed: 19)
        simulate(frozen, seconds: 2, mood: .wild)
        let frozenAt = frozen.pose.position
        frozen.advance(to: 1_000 + frozen.time + 600, mood: .wild, asleep: false)
        check(hypot(frozen.pose.position.x - frozenAt.x, frozen.pose.position.y - frozenAt.y) < 10,
              "reopening the popover after a long gap never teleports the fish")
        if failures > 0 { exit(1) }
    }
}
