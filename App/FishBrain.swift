import CoreGraphics
import Foundation

/// 鱼缸小鱼的性格，按摸鱼率分档（与文案、月热力图同一组阈值）。无数据时是「等待」。
enum FishMood: Equatable {
    case waiting, calm, normal, playful, wild

    init(rate: Int?) {
        guard let rate else { self = .waiting; return }
        switch rate {
        case ...20: self = .calm
        case ...35: self = .normal
        case ...50: self = .playful
        default: self = .wild
        }
    }

    /// 巡游速度（pt/s）
    var speed: Double {
        switch self { case .waiting: return 10; case .calm: return 16; case .normal: return 28; case .playful: return 42; case .wild: return 58 }
    }
    var tailHz: Double {
        switch self { case .waiting: return 1.2; case .calm: return 1.5; case .normal: return 2.1; case .playful: return 2.7; case .wild: return 3.3 }
    }
    /// 游动时尾巴最大摆角（度）
    var tailAmplitude: Double {
        switch self { case .waiting: return 8; case .calm: return 9; case .normal: return 12; case .playful: return 15; case .wild: return 18 }
    }
    var bubbleInterval: Double {
        switch self { case .waiting: return 3.2; case .calm: return 2.6; case .normal: return 1.8; case .playful: return 1.3; case .wild: return 1 }
    }
    /// 只有「尽情游弋」会跃出水面
    var leaps: Bool { self == .wild }
}

/// 某一帧小鱼的姿态，坐标是鱼缸内的点。鱼的原画朝左，facing 为 +1；-1 朝右，介于两者之间即转身时的压扁。
struct FishPose: Equatable {
    var position: CGPoint
    var rotation: Double
    var facing: Double
    var tailAngle: Double
    var finAngle: Double
    /// 1 正常，<1 眨眼，>1 受惊瞪眼
    var eyeOpen: Double
    var pupil: CGVector
    var asleep: Bool
    /// 无数据时的好奇脸（「o」形嘴）
    var curious: Bool

    /// 绘制用的横向缩放：转身经过 0 时保留最小宽度，鱼只变扁不消失
    var drawnFacing: Double { abs(facing) < 0.12 ? (facing < 0 ? -0.12 : 0.12) : facing }
}

struct FishBubble { var position: CGPoint; var radius: Double; var rise: Double; var phase: Double }
struct FishRipple { var position: CGPoint; var age: Double }
struct FishDrop { var position: CGPoint; var velocity: CGVector }
struct FishSnooze { var position: CGPoint; var age: Double }
struct FishPellet { var position: CGPoint }

enum FishTapOutcome: Equatable { case startled, nudged, fed, ignored }

/// 小鱼的行为：巡游、按摸鱼率换性格、跃出水面、睡觉，以及对鼠标悬停、点鱼、投喂的反应。
/// 只用场景时钟（每帧最多推进 1/20 秒），弹窗关闭或滚动冻结后恢复不会瞬移；不依赖界面，可无头测试。
final class FishBrain {
    static let scale = 0.7
    static let surfaceY = 9.0
    static let rippleLifetime = 0.45
    static let snoozeLifetime = 2.6
    private static let leapPeak = 14.0
    private static let leapReach = 60.0
    private static let pelletLimit = 5

    private(set) var size: CGSize
    private(set) var swimArea: CGRect
    private(set) var pose: FishPose
    /// 场景时钟：只在推进时前进，水波和水草也跟着它动
    private(set) var time: TimeInterval = 0
    private(set) var bubbles: [FishBubble] = []
    private(set) var ripples: [FishRipple] = []
    private(set) var drops: [FishDrop] = []
    private(set) var snoozes: [FishSnooze] = []
    private(set) var pellets: [FishPellet] = []
    private(set) var isAsleep = false
    var pointer: CGPoint?

    private var rng: SplitMix64
    private var lastClock: TimeInterval?
    private var body: CGPoint
    private var velocity = CGVector.zero
    private var target: CGPoint
    private var faceTarget = 1.0
    private var phase = 0.0
    private var idleUntil: TimeInterval?
    private var dashUntil = -1.0, wideUntil = -1.0, happyUntil = -1.0, nudgedUntil = -1.0
    private var blinkAt = 2.0, blinkUntil = -1.0
    private var nextBubble = 1.0, nextSnooze = 0.0, nextLeap = 5.0
    private var leap: Leap?
    /// offset：带方向的水平跃出距离
    private struct Leap { let start: TimeInterval; let origin: CGPoint; let offset: Double; var breached = false }

    init(size: CGSize = CGSize(width: 320, height: 88), seed: UInt64 = .random(in: 1...UInt64.max)) {
        self.size = size
        swimArea = Self.swimArea(for: size)
        rng = SplitMix64(seed: seed)
        body = Self.home(for: size)
        target = body
        pose = Self.restingPose(in: size, asleep: false, curious: false)
    }

    /// 左侧约 140pt 留给摸鱼率文字；鱼身半宽约 34pt、半高约 15pt。
    static func swimArea(for size: CGSize) -> CGRect {
        let minX = 176.0, maxX = max(minX, size.width - 36)
        let minY = 26.0, maxY = max(minY, size.height - 22)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func home(for size: CGSize) -> CGPoint { CGPoint(x: size.width - 58, y: 44) }

    /// 静止画面（减弱动态效果、预览截图）用的姿态。
    static func restingPose(in size: CGSize, asleep: Bool, curious: Bool) -> FishPose {
        FishPose(position: asleep ? CGPoint(x: size.width - 58, y: size.height - 20) : home(for: size),
                 rotation: asleep ? -7 : 0, facing: 1, tailAngle: 0, finAngle: 0, eyeOpen: asleep ? 0 : 1,
                 pupil: curious ? CGVector(dx: 0, dy: -1) : .zero, asleep: asleep, curious: curious)
    }

    /// 嘴的位置（原画 24,47），气泡从这里冒出。
    var mouth: CGPoint { point(local: CGPoint(x: -46, y: 1)) }

    func resize(to newSize: CGSize) {
        guard newSize != size, newSize.width > 0, newSize.height > 0 else { return }
        size = newSize
        swimArea = Self.swimArea(for: newSize)
        body = clamped(body)
        target = clamped(target)
    }

    func advance(to clock: TimeInterval, mood: FishMood, asleep: Bool) {
        let dt = lastClock.map { min(max(clock - $0, 0), 0.05) } ?? 0
        lastClock = clock
        guard dt > 0 else { return }
        time += dt
        isAsleep = asleep
        if asleep { sleep(dt) } else { swim(dt, mood: mood) }
        pose.facing += (faceTarget - pose.facing) * min(1, dt * 7)
        pose.position = CGPoint(x: body.x, y: body.y + (asleep ? 0 : sin(time * 2) * 1.5))
        updateParticles(dt)
    }

    @discardableResult
    func tap(at point: CGPoint) -> FishTapOutcome {
        if hypot(point.x - pose.position.x, point.y - pose.position.y) < 24 {
            if isAsleep {
                nudgedUntil = time + 1
                emitBubble(at: mouth)
                return .nudged
            }
            leap = nil
            idleUntil = nil
            dashUntil = time + 0.7
            wideUntil = time + 0.9
            target = CGPoint(x: body.x > swimArea.midX ? swimArea.minX : swimArea.maxX,
                             y: random(swimArea.minY...swimArea.maxY))
            let origin = mouth
            for _ in 0..<7 {
                emitBubble(at: CGPoint(x: origin.x + random(-4...4), y: origin.y + random(-4...4)), radius: random(1.2...3))
            }
            return .startled
        }
        guard !isAsleep, point.y > Self.surfaceY, point.x >= swimArea.minX - 20,
              pellets.count < Self.pelletLimit else { return .ignored }
        pellets.append(FishPellet(position: CGPoint(x: min(point.x, size.width - 12), y: Self.surfaceY + 2)))
        return .fed
    }

    // MARK: - 行为

    private func sleep(_ dt: Double) {
        leap = nil
        velocity = .zero
        body.y += (size.height - 20 - body.y) * min(1, dt * 0.8)
        let pitch = -7 + sin(time * 0.8) * 1.5
        pose.rotation += (pitch * side - pose.rotation) * min(1, dt * 2)
        phase += dt * 2 * .pi * 0.4
        pose.tailAngle = sin(phase) * 3
        pose.finAngle = sin(phase) * 6
        let nudged = time < nudgedUntil
        pose.asleep = !nudged
        pose.eyeOpen = nudged ? 1 : 0
        pose.pupil = .zero
        pose.curious = false
        if time >= nextSnooze {
            nextSnooze = time + 1.8
            snoozes.append(FishSnooze(position: point(local: CGPoint(x: -26, y: -20)), age: 0))
        }
    }

    private func swim(_ dt: Double, mood: FishMood) {
        pose.asleep = false
        pose.curious = mood == .waiting
        if var current = leap {
            let progress = (time - current.start) / 1.0
            let previous = body
            if progress >= 1 {
                leap = nil
                body = CGPoint(x: current.origin.x + current.offset, y: current.origin.y)
                velocity = CGVector(dx: 0, dy: 30)
            } else {
                body.x = current.origin.x + current.offset * progress
                body.y = current.origin.y - (current.origin.y - Self.leapPeak) * 4 * progress * (1 - progress)
                let breached = body.y < Self.surfaceY + 10
                if breached != current.breached {
                    current.breached = breached
                    splash(at: body.x)
                }
                leap = current
                velocity = CGVector(dx: (body.x - previous.x) / dt, dy: (body.y - previous.y) / dt)
            }
        } else {
            var speed = mood.speed
            chooseTarget(mood: mood, speed: &speed)
            if time < dashUntil { speed *= 3.2 }
            steer(dt, speed: speed)
            if mood.leaps, time >= nextLeap, pellets.isEmpty, time >= dashUntil { startLeap() }
        }

        if velocity.dx < -4 { faceTarget = 1 } else if velocity.dx > 4 { faceTarget = -1 }
        let pitch = atan2(-velocity.dy, max(4, abs(velocity.dx))) * 180 / .pi
        pose.rotation += (min(max(pitch, -28), 28) * side - pose.rotation) * min(1, dt * 6)
        let pace = min(1.6, hypot(velocity.dx, velocity.dy) / mood.speed)
        let happy = time < happyUntil
        phase += dt * 2 * .pi * mood.tailHz * (0.6 + 0.6 * pace) * (happy ? 1.8 : 1)
        pose.tailAngle = sin(phase) * mood.tailAmplitude * (0.45 + 0.6 * min(pace, 1)) * (happy ? 1.3 : 1)
        pose.finAngle = sin(phase * 0.5 + 1) * 20
        if time >= blinkAt {
            blinkUntil = time + 0.14
            blinkAt = time + random(2.5...6)
        }
        pose.eyeOpen = time < wideUntil ? 1.18 : time < blinkUntil ? 0.1 : 1
        pose.pupil = gaze(curious: pose.curious)
        if time >= nextBubble, leap == nil {
            nextBubble = time + mood.bubbleInterval * random(0.7...1.3)
            emitBubble(at: mouth)
        }
    }

    /// 选目标：鱼食优先，其次靠近鼠标，否则在游动区随机巡游。
    private func chooseTarget(mood: FishMood, speed: inout Double) {
        if let index = pellets.indices.min(by: { distance(pellets[$0].position, body) < distance(pellets[$1].position, body) }) {
            let pellet = pellets[index].position
            let approach: Double = body.x >= pellet.x ? 1 : -1
            target = CGPoint(x: pellet.x + 30 * approach, y: min(pellet.y, swimArea.maxY + CGFloat(6)))
            speed = max(speed, 40)
            if distance(mouth, pellet) < 11 {
                pellets.remove(at: index)
                happyUntil = time + 0.8
                emitBubble(at: mouth, radius: 2)
            }
            return
        }
        if let pointer, CGRect(origin: .zero, size: size).contains(pointer),
           pointer.x >= swimArea.minX - 30, time >= dashUntil {
            let approach: Double = body.x < pointer.x ? -1 : 1
            target = clamped(CGPoint(x: pointer.x + 34 * approach, y: pointer.y))
            speed *= 0.8
            return
        }
        guard distance(target, body) < 6 else { return }
        if idleUntil == nil { idleUntil = time + random(0.3...1.4) }
        if let idle = idleUntil, time >= idle {
            idleUntil = nil
            if mood == .waiting {
                let home = Self.home(for: size)
                target = clamped(CGPoint(x: home.x + random(-12...12), y: home.y + random(-6...6)))
            } else {
                target = CGPoint(x: random(swimArea.minX...swimArea.maxX), y: random(swimArea.minY...swimArea.maxY))
            }
        }
    }

    private func steer(_ dt: Double, speed: Double) {
        let dx = target.x - body.x, dy = target.y - body.y
        let length = max(hypot(dx, dy), 0.001)
        let arrival = min(1, length / 30)
        let blend = min(1, dt * 2.5)
        velocity.dx += (dx / length * speed * arrival - velocity.dx) * blend
        velocity.dy += (dy / length * speed * arrival - velocity.dy) * blend
        body.x += velocity.dx * dt
        body.y += velocity.dy * dt
    }

    private func startLeap() {
        nextLeap = time + random(6...9)
        // 朝鼻子方向跳；那一侧不够 30pt 就掉头，跳的距离不超过游动区边界
        let roomLeft = body.x - swimArea.minX, roomRight = swimArea.maxX - body.x
        let ahead: Double = side > 0 ? -1 : 1
        let direction = (ahead < 0 ? roomLeft : roomRight) >= 30 ? ahead : -ahead
        let reach = min(Self.leapReach, direction < 0 ? roomLeft : roomRight)
        guard reach >= 30 else { return }
        leap = Leap(start: time, origin: body, offset: direction * reach)
        faceTarget = direction < 0 ? 1 : -1
    }

    private func gaze(curious: Bool) -> CGVector {
        guard let pointer else { return curious ? CGVector(dx: 0, dy: -1) : .zero }
        return CGVector(dx: min(max((pointer.x - pose.position.x) / 25 * side, -1.6), 1.6),
                        dy: min(max((pointer.y - pose.position.y) / 25, -1.4), 1.4))
    }

    // MARK: - 粒子

    private func updateParticles(_ dt: Double) {
        bubbles = bubbles.compactMap { bubble in
            var bubble = bubble
            bubble.position.y -= bubble.rise * dt
            bubble.position.x += cos(time * 3 + bubble.phase) * 6 * dt
            bubble.radius += dt * 0.4
            if bubble.position.y < Self.surfaceY + 2 {
                ripples.append(FishRipple(position: CGPoint(x: bubble.position.x, y: Self.surfaceY + 1), age: 0))
                return nil
            }
            return bubble
        }
        ripples = ripples.compactMap { ripple in
            var ripple = ripple
            ripple.age += dt
            return ripple.age < Self.rippleLifetime ? ripple : nil
        }
        drops = drops.compactMap { drop in
            var drop = drop
            drop.velocity.dy += 120 * dt
            drop.position.x += drop.velocity.dx * dt
            drop.position.y += drop.velocity.dy * dt
            return drop.velocity.dy > 0 && drop.position.y > Self.surfaceY + 3 ? nil : drop
        }
        snoozes = snoozes.compactMap { snooze in
            var snooze = snooze
            snooze.age += dt
            snooze.position.x += 5 * dt
            snooze.position.y -= 7 * dt
            return snooze.age < Self.snoozeLifetime ? snooze : nil
        }
        for index in pellets.indices {
            pellets[index].position.y = min(size.height - 10, pellets[index].position.y + 16 * dt)
            pellets[index].position.x += cos(time * 2 + Double(index)) * 2 * dt
        }
    }

    private func emitBubble(at point: CGPoint, radius: Double? = nil) {
        bubbles.append(FishBubble(position: point, radius: radius ?? random(1.6...3.6),
                                  rise: random(10...18), phase: random(0...6)))
        if bubbles.count > 30 { bubbles.removeFirst(bubbles.count - 30) }
    }

    private func splash(at x: Double) {
        ripples.append(FishRipple(position: CGPoint(x: x, y: Self.surfaceY), age: 0))
        for _ in 0..<6 {
            drops.append(FishDrop(position: CGPoint(x: x, y: Self.surfaceY),
                                  velocity: CGVector(dx: random(-22...22), dy: random(-40 ... -20))))
        }
    }

    // MARK: - 工具

    private var side: Double { pose.facing >= 0 ? 1 : -1 }

    /// 原画坐标（以 70,46 为原点）换算到鱼缸坐标，与绘制时的变换一致。
    private func point(local: CGPoint) -> CGPoint {
        let x = local.x * Self.scale * pose.drawnFacing, y = local.y * Self.scale
        let angle = pose.rotation * .pi / 180
        return CGPoint(x: pose.position.x + x * cos(angle) - y * sin(angle),
                       y: pose.position.y + x * sin(angle) + y * cos(angle))
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, swimArea.minX), swimArea.maxX), y: min(max(point.y, swimArea.minY), swimArea.maxY))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private func random(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &rng) }
}

/// 可复现的随机数，测试用固定种子。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
