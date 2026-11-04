import Cocoa

@main
struct AppearanceRegression {
    static func main() {
        let _ = NSApplication.shared
        var failures = 0
        func rgb(_ color: NSColor, _ appearance: NSAppearance) -> [Double] {
            var result: [Double] = []
            appearance.performAsCurrentDrawingAppearance {
                let c = color.usingColorSpace(.sRGB)!
                result = [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)
            }
            return result
        }
        func luminance(_ color: [Double]) -> Double {
            let linear = color.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        func contrast(_ a: [Double], _ b: [Double]) -> Double {
            let x = luminance(a), y = luminance(b)
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        func check(_ pass: Bool, _ description: String) {
            print("\(pass ? "PASS" : "FAIL") \(description)")
            if !pass { failures += 1 }
        }
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = NSAppearance(named: name)!
            let work = rgb(Palette.workNS, appearance), slack = rgb(Palette.slackNS, appearance)
            check(work[1] > work[0] && slack[0] > slack[1], "work teal / leisure orange in \(name.rawValue)")
            let background = rgb(.windowBackgroundColor, appearance)
            for (label, color) in [("secondary text", Palette.ink3NS), ("work text", Palette.workDeepNS),
                                   ("leisure text", Palette.slackDeepNS)] {
                let ratio = contrast(rgb(color, appearance), background)
                check(ratio >= 4.5, "\(label) contrast \(String(format: "%.2f", ratio)) in \(name.rawValue)")
            }
            for index in Palette.heatNS.indices {
                check(contrast(rgb(Palette.heatTextNS[index], appearance), rgb(Palette.heatNS[index], appearance)) >= 4.5,
                      "calendar text contrast level \(index) in \(name.rawValue)")
            }
            check(contrast(rgb(Palette.brandButtonTextNS, appearance), rgb(Palette.brandDeepNS, appearance)) >= 4.5,
                  "primary authorization button text remains readable in \(name.rawValue)")
            check(contrast([1, 1, 1], rgb(Palette.pillTopNS, appearance)) >= 4.5,
                  "menu bar pill text remains readable in \(name.rawValue)")
        }
        let dark = NSAppearance(named: .darkAqua)!, high = NSAppearance(named: .accessibilityHighContrastDarkAqua)!
        check(rgb(Palette.workNS, dark) == rgb(Palette.workNS, high), "high contrast dark mode uses the dark palette")
        if failures > 0 { exit(1) }
    }
}
