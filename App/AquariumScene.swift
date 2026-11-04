import SwiftUI

/// 鱼缸场景的 Canvas 绘制：水面、水草、小鱼和粒子。
/// 鱼的轮廓照搬 fish-normal.svg（120×90 画布，以 70,46 为中心），拆成可单独转动的尾巴、胸鳍和眼睛。
struct AquariumScenePainter {
    let dark: Bool

    func paint(_ context: GraphicsContext, size: CGSize, brain: FishBrain) {
        paintWater(context, size: size, time: brain.time, calm: brain.isAsleep)
        // 气泡在鱼身后，鱼游过时不会盖住眼睛
        for bubble in brain.bubbles { paintBubble(at: bubble.position, radius: bubble.radius, in: context) }
        paintFish(brain.pose, in: context)
        for ripple in brain.ripples {
            var layer = context
            layer.opacity = 1 - ripple.age / FishBrain.rippleLifetime
            let rx = 2 + ripple.age * 16, ry = 0.8 + ripple.age * 3
            layer.stroke(Path(ellipseIn: CGRect(x: ripple.position.x - rx, y: ripple.position.y - ry, width: rx * 2, height: ry * 2)),
                         with: .color(bubbleEdge), lineWidth: 0.8)
        }
        for drop in brain.drops { context.fill(circle(drop.position, 1.3), with: .color(bubbleEdge)) }
        for snooze in brain.snoozes {
            var layer = context
            layer.opacity = max(0, 1 - snooze.age / FishBrain.snoozeLifetime)
            paintSnooze("z", at: snooze.position, size: 8 + snooze.age * 2.5, in: layer)
        }
        for pellet in brain.pellets {
            context.fill(circle(pellet.position, 2), with: .color(rgb(0xB45309)))
            context.fill(circle(CGPoint(x: pellet.position.x - 0.6, y: pellet.position.y - 0.6), 0.6), with: .color(rgb(0xFCD34D)))
        }
    }

    /// 静止画面：减弱动态效果和预览截图用，不推进任何行为。
    func paintStill(_ context: GraphicsContext, size: CGSize, asleep: Bool, curious: Bool) {
        paintWater(context, size: size, time: 0, calm: true)
        let pose = FishBrain.restingPose(in: size, asleep: asleep, curious: curious)
        paintFish(pose, in: context)
        let at = pose.position
        if asleep {
            paintSnooze("z", at: CGPoint(x: at.x - 24, y: at.y - 18), size: 8, in: context)
            paintSnooze("Z", at: CGPoint(x: at.x - 15, y: at.y - 26), size: 10, in: context)
        } else {
            paintBubble(at: CGPoint(x: at.x - 38, y: at.y - 13), radius: 3.2, in: context)
            paintBubble(at: CGPoint(x: at.x - 29, y: at.y - 22), radius: 2, in: context)
        }
    }

    // MARK: - 水

    private func paintWater(_ context: GraphicsContext, size: CGSize, time: Double, calm: Bool) {
        var surface = Path()
        var x = 0.0
        while x <= size.width + 8 {
            let point = CGPoint(x: x, y: FishBrain.surfaceY + sin(x / 18 + time * 1.6) * 1.2)
            if x == 0 { surface.move(to: point) } else { surface.addLine(to: point) }
            x += 8
        }
        var air = surface
        air.addLine(to: CGPoint(x: size.width + 8, y: 0))
        air.addLine(to: .zero)
        air.closeSubpath()
        context.fill(air, with: .color(dark ? .white.opacity(0.05) : .white.opacity(0.55)))
        context.stroke(surface, with: .color(dark ? rgb(0x2DD4BF).opacity(0.45) : rgb(0x99F6E4)), lineWidth: 1.2)

        let pebble = dark ? rgb(0x115E59) : rgb(0xCCFBF1)
        context.fill(Path(ellipseIn: CGRect(x: size.width - 100, y: size.height - 3.5, width: 20, height: 7)), with: .color(pebble))
        context.fill(Path(ellipseIn: CGRect(x: size.width - 78, y: size.height - 2.5, width: 12, height: 5)), with: .color(pebble))

        let weed = dark ? rgb(0x14B8A6).opacity(0.45) : rgb(0x5EEAD4).opacity(0.7)
        for (index, strand) in [(size.width - 24, 1.0), (size.width - 14, 1.3), (size.width - 150, 0.8)].enumerated() {
            let sway = sin(time * 1.2 + Double(index)) * 4 * (calm ? 0.4 : 1)
            var path = Path()
            path.move(to: CGPoint(x: strand.0, y: size.height))
            path.addQuadCurve(to: CGPoint(x: strand.0 + sway * 1.6, y: size.height - 26 * strand.1),
                              control: CGPoint(x: strand.0 + sway, y: size.height - 14 * strand.1))
            context.stroke(path, with: .color(weed), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    // MARK: - 鱼

    private func paintFish(_ pose: FishPose, in context: GraphicsContext) {
        var fish = context
        fish.translateBy(x: pose.position.x, y: pose.position.y)
        fish.rotate(by: .degrees(pose.rotation))
        fish.scaleBy(x: pose.drawnFacing * FishBrain.scale, y: FishBrain.scale)
        fish.translateBy(x: -70, y: -46)

        var tail = fish
        pivot(&tail, around: CGPoint(x: 78, y: 46), degrees: pose.tailAngle)
        paintFin(FishShapes.tail, in: tail)
        paintFin(FishShapes.dorsal, in: fish)
        paintFin(FishShapes.pelvic, in: fish)
        fish.fill(FishShapes.body, with: .linearGradient(Gradient(colors: [rgb(0xFB923C), rgb(0xEA580C)]),
                                                          startPoint: CGPoint(x: 20, y: 20), endPoint: CGPoint(x: 80, y: 70)))
        fish.stroke(FishShapes.body, with: .color(outline), lineWidth: 1.8)
        fish.fill(FishShapes.belly, with: .color(rgb(0xFED7AA).opacity(0.9)))
        var fin = fish
        pivot(&fin, around: CGPoint(x: 46, y: 50), degrees: pose.finAngle)
        fin.fill(FishShapes.pectoral, with: .color(rgb(0xFDBA74)))
        fin.stroke(FishShapes.pectoral, with: .color(finEdge), lineWidth: 1.4)
        paintEye(pose, in: fish)
        fish.fill(Path(ellipseIn: CGRect(x: 35.5, y: 45.5, width: 9, height: 5)), with: .color(rgb(0xFB7185).opacity(0.4)))
        if pose.curious {
            fish.stroke(Path(ellipseIn: CGRect(x: 23.5, y: 45, width: 3, height: 4)), with: .color(outline), lineWidth: 1.4)
        } else {
            fish.stroke(FishShapes.mouth, with: .color(outline), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }

    private func paintEye(_ pose: FishPose, in fish: GraphicsContext) {
        if pose.asleep {
            fish.stroke(FishShapes.closedEye, with: .color(outline), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            return
        }
        var eye = fish
        eye.translateBy(x: 37, y: 38)
        eye.scaleBy(x: pose.eyeOpen > 1 ? 1.08 : 1, y: pose.eyeOpen)
        eye.translateBy(x: -37, y: -38)
        let white = Path(ellipseIn: CGRect(x: 28.5, y: 29, width: 17, height: 18))
        eye.fill(white, with: .color(.white))
        var pupil = eye
        pupil.clip(to: white)
        pupil.translateBy(x: pose.pupil.dx, y: pose.pupil.dy)
        pupil.fill(circle(CGPoint(x: 36, y: 38.5), 5.5), with: .color(rgb(0x18181B)))
        pupil.fill(circle(CGPoint(x: 33.8, y: 36), 2.2), with: .color(.white))
        pupil.fill(circle(CGPoint(x: 38.5, y: 41), 1.1), with: .color(.white))
        eye.stroke(white, with: .color(outline), lineWidth: 1.6)
    }

    private func paintFin(_ path: Path, in context: GraphicsContext) {
        context.fill(path, with: .linearGradient(Gradient(colors: [rgb(0xFDBA74).opacity(0.9), rgb(0xEA580C).opacity(0.65)]),
                                                 startPoint: CGPoint(x: 75, y: 35), endPoint: CGPoint(x: 115, y: 65)))
        context.stroke(path, with: .color(finEdge), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
    }

    private func pivot(_ context: inout GraphicsContext, around point: CGPoint, degrees: Double) {
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: .degrees(degrees))
        context.translateBy(x: -point.x, y: -point.y)
    }

    // MARK: - 粒子

    private func paintBubble(at point: CGPoint, radius: Double, in context: GraphicsContext) {
        let bubble = circle(point, radius)
        context.fill(bubble, with: .color(dark ? rgb(0x0C4A6E).opacity(0.55) : rgb(0xE0F2FE).opacity(0.75)))
        context.stroke(bubble, with: .color(bubbleEdge), lineWidth: 0.9)
        context.fill(circle(CGPoint(x: point.x - radius * 0.35, y: point.y - radius * 0.35), radius * 0.3), with: .color(.white))
    }

    private func paintSnooze(_ letter: String, at point: CGPoint, size: Double, in context: GraphicsContext) {
        context.draw(Text(letter).font(.system(size: size, weight: .heavy))
            .foregroundColor(dark ? rgb(0x5EEAD4) : rgb(0x0D9488)), at: point)
    }

    // MARK: - 颜色与形状

    private var outline: Color { rgb(0x9A3412) }
    private var finEdge: Color { rgb(0xEA580C) }
    private var bubbleEdge: Color { rgb(0x38BDF8).opacity(dark ? 0.8 : 1) }

    private func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }

    private func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// fish-normal.svg / fish-paused.svg 的路径，逐段照搬三次贝塞尔控制点。
private enum FishShapes {
    static let tail = outline(78, 46, [[88, 32, 106, 24, 114, 30], [117, 34, 108, 44, 115, 54],
                                       [118, 59, 112, 68, 98, 62], [88, 58, 82, 52, 78, 46]])
    static let dorsal = outline(46, 27, [[54, 18, 68, 19, 74, 27], [66, 28, 56, 29, 46, 27]])
    static let pelvic = outline(52, 64, [[56, 73, 67, 74, 70, 67], [65, 64, 58, 63, 52, 64]])
    static let body = outline(24, 45, [[24, 30, 44, 24, 68, 27], [83, 29, 86, 44, 84, 51],
                                       [80, 62, 62, 67, 44, 65], [29, 64, 24, 55, 24, 45]])
    static let belly = outline(30, 52, [[34, 61, 52, 65, 70, 60], [62, 55, 42, 51, 30, 52]])
    static let pectoral = outline(44, 49, [[41, 57, 47, 67, 57, 68], [60, 67, 61, 62, 57, 57], [54, 53, 49, 50, 44, 49]])
    static let mouth: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 24, y: 46))
        path.addQuadCurve(to: CGPoint(x: 25, y: 50), control: CGPoint(x: 28, y: 48))
        return path
    }()
    static let closedEye: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 31, y: 40))
        path.addCurve(to: CGPoint(x: 42, y: 40), control1: CGPoint(x: 33, y: 35), control2: CGPoint(x: 39, y: 35))
        return path
    }()

    private static func outline(_ x: CGFloat, _ y: CGFloat, _ curves: [[CGFloat]]) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x, y: y))
        for c in curves {
            path.addCurve(to: CGPoint(x: c[4], y: c[5]), control1: CGPoint(x: c[0], y: c[1]), control2: CGPoint(x: c[2], y: c[3]))
        }
        path.closeSubpath()
        return path
    }
}
