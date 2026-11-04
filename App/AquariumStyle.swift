import Cocoa
import SwiftUI

/// Tokens frozen from the current OpenDesign Pocket Aquarium artifact.
enum AquariumStyle {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color { Color(nsColor: nsColor(light, dark)) }
    static func nsColor(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        }
    }
    static var background: Color { color(0xFFFFFF, 0x18181B) }
    static var surface: Color { color(0xF8FAFC, 0x27272A) }
    static var subtle: Color { color(0xF1F5F9, 0x202023) }
    static var ink: Color { color(0x09090B, 0xF4F4F5) }
    static var muted: Color { color(0x64748B, 0xA1A1AA) }
    static var border: Color { color(0xE2E8F0, 0x3F3F46) }
    static var work: Color { color(0x0D9488, 0x14B8A6) }
    static var workText: Color { color(0x0F766E, 0x5EEAD4) }
    static var leisure: Color { color(0xEA580C, 0xF97316) }
    static var leisureText: Color { color(0xC2410C, 0xFDBA74) }
    static var habitatTop: Color { color(0xF0FDFA, 0x132E2B) }
    static var habitatBottom: Color { color(0xE6FFFA, 0x0F2926) }
    static var habitatBorder: Color { color(0xCCFBF1, 0x115E59) }
    static var running: Color { Color(red: 16/255, green: 185/255, blue: 129/255) }
    static var paused: Color { Color(red: 239/255, green: 68/255, blue: 68/255) }
    static var heat: [Color] {
        [color(0xFFEDD5, 0x431407), color(0xFED7AA, 0x7C2D12),
         color(0xFB923C, 0x9A3412), color(0xEA580C, 0xC2410C)]
    }
    static func heatText(level: Int) -> Color {
        level < 2 ? color(0x7C2D12, 0xFFEDD5) : color(0x09090B, 0xFFFFFF)
    }
    static func category(_ category: AppCategory) -> Color {
        switch category { case .work: return work; case .slack: return leisure; case .ignored: return muted }
    }
    static func duration(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000), minutes = seconds / 60
        if minutes >= 60 { return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" }
        if minutes > 0 { return "\(minutes)m" }
        return seconds > 0 ? "\(seconds)s" : "0m"
    }
}

enum AquariumAsset {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        let directory = ProcessInfo.processInfo.environment["MOYU_ASSET_DIR"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("Aquarium")
        guard let url = directory?.appendingPathComponent(name + ".svg"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        cache[name] = image
        return image
    }
}

struct AquariumArtwork: View {
    let name: String
    var body: some View {
        if let image = AquariumAsset.image(name) {
            Image(nsImage: image).resizable().renderingMode(name == "logo-mark" ? .template : .original)
                .aspectRatio(contentMode: .fit).foregroundStyle(AquariumStyle.leisure).accessibilityHidden(true)
        } else {
            Image(systemName: "fish.fill").resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(AquariumStyle.leisure).accessibilityHidden(true)
        }
    }
}
