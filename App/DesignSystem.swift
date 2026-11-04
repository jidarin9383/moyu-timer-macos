import Cocoa
import CoreText
import SwiftUI

/// Semantic colors: work is teal, leisure is orange, and ignored usage is neutral.
/// Brand controls retain their teal identity independently of usage categories.
enum Palette {
    static let brandNS = dyn(light: (0.137, 0.702, 0.659), dark: (0.275, 0.839, 0.784))
    static let brandDeepNS = dyn(light: (0.063, 0.455, 0.431), dark: (0.498, 0.847, 0.812))
    static let brandTintNS = dyn(light: (0.882, 0.957, 0.949), dark: (0.090, 0.247, 0.239))

    static let brandButtonTextNS = dyn(light: (1.000, 1.000, 1.000), dark: (0.024, 0.196, 0.176))

    static let workNS = brandNS
    static let workDeepNS = brandDeepNS
    static let workTintNS = brandTintNS
    static let slackNS = dyn(light: (0.941, 0.584, 0.173), dark: (1.000, 0.659, 0.408))
    static let slackDeepNS = dyn(light: (0.651, 0.353, 0.071), dark: (1.000, 0.725, 0.522))
    static let slackTintNS = dyn(light: (0.988, 0.937, 0.878), dark: (0.239, 0.165, 0.086))
    static let pillTopNS = dyn(light: (0.075, 0.486, 0.463), dark: (0.075, 0.486, 0.463))
    static let pillBottomNS = dyn(light: (0.051, 0.384, 0.369), dark: (0.051, 0.384, 0.369))

    // 已忽略 · 石灰（退到岸边，不计入）
    static let ignoredNS = dyn(light: (0.604, 0.655, 0.706), dark: (0.420, 0.482, 0.541))       // #9AA7B4 / #6B7B8A

    // 文字
    static let inkNS = dyn(light: (0.133, 0.192, 0.243), dark: (0.914, 0.945, 0.961))           // #22313E / #E9F1F5
    static let ink2NS = dyn(light: (0.310, 0.380, 0.440), dark: (0.561, 0.639, 0.710))
    static let ink3NS = dyn(light: (0.350, 0.410, 0.460), dark: (0.569, 0.639, 0.694))          // Secondary labels remain readable in either appearance.

    // 轨道与容器
    static let trackNS = dyn(light: (0.933, 0.949, 0.965), dark: (0.133, 0.192, 0.243))         // #EEF2F6 / #22313E
    static let tabBgNS = dyn(light: (0.945, 0.957, 0.969), dark: (0.133, 0.192, 0.243))         // #F1F4F7 / #22313E
    static let rowHoverNS = dyn(light: (0.969, 0.980, 0.984), dark: (0.157, 0.212, 0.247))      // #F7FAFB / #28363F
    static let domainBgNS = dyn(light: (0.973, 0.980, 0.984), dark: (0.137, 0.184, 0.212))      // #F8FAFB / #232F38
    static let heatTextLightNS = NSColor(calibratedRed: 0.133, green: 0.192, blue: 0.243, alpha: 1) // #22313E

    // Leisure rate increases from a pale orange tint to the leisure accent.
    static let heatNS: [NSColor] = [
        dyn(light: (1.000, 0.969, 0.929), dark: (0.188, 0.145, 0.098)),
        dyn(light: (0.992, 0.902, 0.780), dark: (0.329, 0.224, 0.125)),
        dyn(light: (0.976, 0.808, 0.600), dark: (0.486, 0.318, 0.165)),
        dyn(light: (0.961, 0.706, 0.400), dark: (0.706, 0.451, 0.196)),
        slackNS,
    ]

    static let heatTextNS: [NSColor] = heatNS.map { background in
        NSColor(name: nil, dynamicProvider: { appearance in
            var resolved = NSColor.black
            appearance.performAsCurrentDrawingAppearance {
                resolved = background.usingColorSpace(.sRGB) ?? background
            }
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * linear(resolved.redComponent)
                + 0.7152 * linear(resolved.greenComponent) + 0.0722 * linear(resolved.blueComponent)
            return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? .black : .white
        })
    }

    private static func dyn(light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: "Palette-\(light.0)-\(light.1)-\(dark.0)", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: 1)
                : NSColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: 1)
        })
    }

    // SwiftUI colors.
    static var brand: Color { Color(nsColor: brandNS) }
    static var brandDeep: Color { Color(nsColor: brandDeepNS) }
    static var brandTint: Color { Color(nsColor: brandTintNS) }
    static var brandButtonText: Color { Color(nsColor: brandButtonTextNS) }
    static var heatText: [Color] { heatTextNS.map { Color(nsColor: $0) } }
    static var work: Color { Color(nsColor: workNS) }
    static var workDeep: Color { Color(nsColor: workDeepNS) }
    static var workTint: Color { Color(nsColor: workTintNS) }
    static var slack: Color { Color(nsColor: slackNS) }
    static var slackDeep: Color { Color(nsColor: slackDeepNS) }
    static var slackTint: Color { Color(nsColor: slackTintNS) }
    static var ignored: Color { Color(nsColor: ignoredNS) }
    static var ink: Color { Color(nsColor: inkNS) }
    static var ink2: Color { Color(nsColor: ink2NS) }
    static var ink3: Color { Color(nsColor: ink3NS) }
    static var track: Color { Color(nsColor: trackNS) }
    static var tabBg: Color { Color(nsColor: tabBgNS) }
    static var rowHover: Color { Color(nsColor: rowHoverNS) }
    static var domainBg: Color { Color(nsColor: domainBgNS) }
    static var heat: [Color] { heatNS.map { Color(nsColor: $0) } }
}

// MARK: - 鱼形（设计稿统一的小鱼剪影）

/// 设计稿鱼形 path（24×24 viewBox）：侧身、尾鳍在右。
/// 用法：`FishShape().fill(color)`，眼睛另用 Circle 叠加（常与身体不同色）。
struct FishShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24, sy = rect.height / 24
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(3.2, 12))
        path.addCurve(to: p(10.2, 5.8), control1: p(3.2, 8.4), control2: p(6.6, 5.8))
        path.addCurve(to: p(15.4, 7.9), control1: p(12.5, 5.8), control2: p(14.3, 6.7))
        path.addLine(to: p(20, 5.3))
        path.addLine(to: p(18.6, 9.6))
        path.addCurve(to: p(19.4, 11.9), control1: p(19.1, 10.2), control2: p(19.4, 10.9))
        path.addCurve(to: p(18.6, 14.2), control1: p(19.4, 12.9), control2: p(19.1, 13.6))
        path.addLine(to: p(20, 18.5))
        path.addLine(to: p(15.4, 15.9))
        path.addCurve(to: p(10.2, 18.1), control1: p(14.3, 17.2), control2: p(12.5, 18.1))
        path.addCurve(to: p(3.2, 12), control1: p(6.6, 18.1), control2: p(3.2, 15.5))
        path.closeSubpath()
        return path
    }
}

/// AppKit 侧鱼形 path（与 FishShape 同源，供菜单栏药丸绘制）。
enum FishBezier {
    static func path(in rect: CGRect) -> NSBezierPath {
        let sx = rect.width / 24, sy = rect.height / 24
        func p(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        let path = NSBezierPath()
        path.move(to: p(3.2, 12))
        path.curve(to: p(10.2, 5.8), controlPoint1: p(3.2, 8.4), controlPoint2: p(6.6, 5.8))
        path.curve(to: p(15.4, 7.9), controlPoint1: p(12.5, 5.8), controlPoint2: p(14.3, 6.7))
        path.line(to: p(20, 5.3))
        path.line(to: p(18.6, 9.6))
        path.curve(to: p(19.4, 11.9), controlPoint1: p(19.1, 10.2), controlPoint2: p(19.4, 10.9))
        path.curve(to: p(18.6, 14.2), controlPoint1: p(19.4, 12.9), controlPoint2: p(19.1, 13.6))
        path.line(to: p(20, 18.5))
        path.line(to: p(15.4, 15.9))
        path.curve(to: p(10.2, 18.1), controlPoint1: p(14.3, 17.2), controlPoint2: p(12.5, 18.1))
        path.curve(to: p(3.2, 12), controlPoint1: p(6.6, 18.1), controlPoint2: p(3.2, 15.5))
        path.close()
        return path
    }
}

/// 小鱼图标（身体 + 眼睛）。眼睛色默认白，深底上自动醒目。
struct FishIcon: View {
    var size: CGFloat = 15
    var color: Color = Palette.brand
    var eyeColor: Color = .white
    var rotation: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            FishShape().fill(color)
            Circle()
                .fill(eyeColor)
                .frame(width: max(1.5, size * 0.11), height: max(1.5, size * 0.11))
                .offset(x: size * (7.6 / 24) - max(1.5, size * 0.11) / 2,
                        y: size * (10.6 / 24) - max(1.5, size * 0.11) / 2)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation))
    }
}

// MARK: - 潜水等级（按摸鱼率四档，全 App 唯一允许「俏皮」的位置）

enum DiveRank {
    case shallow    // 浅水试探
    case relaxed    // 悠然划水
    case swimmer    // 自由泳健将
    case diver      // 深海潜泳者

    /// 分档与设计稿示例数据一致：40% → 悠然划水，42%/45% → 自由泳健将。
    static func rank(rate: Double) -> DiveRank {
        if rate < 0.20 { return .shallow }
        if rate <= 0.40 { return .relaxed }
        if rate < 0.70 { return .swimmer }
        return .diver
    }

    var title: String {
        switch self {
        case .shallow: return "浅水试探"
        case .relaxed: return "悠然划水"
        case .swimmer: return "自由泳健将"
        case .diver: return "深海潜泳者"
        }
    }
}

/// 潜水等级徽章：浅青底 + 小鱼 + 文案。
struct DiveRankBadge: View {
    let rank: DiveRank

    var body: some View {
        HStack(spacing: 5) {
            FishShape()
                .fill(Palette.slackDeep)
                .frame(width: 11, height: 11)
            Text(rank.title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Palette.slackDeep)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Palette.slackTint)
        .clipShape(Capsule())
    }
}

// MARK: - 菜单栏药丸

/// 菜单栏显示形态（右键「菜单栏显示」切换，UserDefaults 持久化）。
enum MenuBarStyle: String, CaseIterable {
    case rate = "摸鱼率"
    case duration = "摸鱼时长"
    case spark = "迷你柱图"
    case plain = "纯图标"

    static let preferenceKey = "menuBarStyle"

    static var current: MenuBarStyle {
        get { MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .rate }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }
}

/// 菜单栏药丸：NSImage 直接绘制（AppKit），retina 下清晰。
/// 形态：摸鱼率（默认）/ 摸鱼时长 / 迷你柱图 / 纯图标。
/// 文字与鱼为白色（药丸底上）或湖水青（纯图标）。
enum MenuBarPill {
    static func image(style: MenuBarStyle, text: String, spark: [Double] = []) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white
        ]))
        // Center visible glyphs, rather than the font's line box and internal leading.
        let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let fish = FishBezier.path(in: CGRect(x: 0, y: 0, width: 13, height: 13))
        let fishBounds = fish.bounds
        let hasPill = style != .plain
        let values = Array(spark.prefix(4))
        let barW: CGFloat = 3.4, gap: CGFloat = 1.5
        let sparkW = CGFloat(max(1, values.count)) * barW + CGFloat(max(0, values.count - 1)) * gap
        let contentW = style == .spark ? sparkW
            : fishBounds.width + (hasPill && !text.isEmpty ? 4 + textBounds.width : 0)
        let totalW = ceil(contentW + (hasPill ? 12 : 4))

        let image = NSImage(size: NSSize(width: totalW, height: 20), flipped: false) { rect in
            if hasPill {
                let pillRect = rect.insetBy(dx: 0, dy: 1.5)
                let path = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2,
                                        yRadius: pillRect.height / 2)
                NSGradient(colors: [Palette.pillTopNS, Palette.pillBottomNS])?.draw(in: path, angle: -90)
            }
            (hasPill ? NSColor.white : Palette.brandNS).setFill()
            let startX = rect.midX - contentW / 2
            if style == .spark {
                for (index, value) in values.enumerated() {
                    let height = max(2.5, 12 * CGFloat(min(1, max(0, value))))
                    NSBezierPath(roundedRect: NSRect(x: startX + CGFloat(index) * (barW + gap),
                                                    y: rect.midY - 6, width: barW, height: height),
                                 xRadius: 1.7, yRadius: 1.7).fill()
                }
            } else {
                let centeredFish = fish.copy() as! NSBezierPath
                var transform = AffineTransform()
                transform.translate(x: startX - fishBounds.minX, y: rect.midY - fishBounds.midY)
                centeredFish.transform(using: transform)
                centeredFish.fill()
                if hasPill && !text.isEmpty, let context = NSGraphicsContext.current?.cgContext {
                    context.saveGState()
                    context.textMatrix = .identity
                    context.textPosition = CGPoint(x: startX + fishBounds.width + 4 - textBounds.minX,
                                                   y: rect.midY - textBounds.midY)
                    CTLineDraw(line, context)
                    context.restoreGState()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
