import Cocoa
import SwiftUI

/// Pure fixed-data fidelity stage: no Store, tracker, network or permissions are instantiated.
@main
struct AquariumStaticPreview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let summary = AquariumSummary(workMs: 198 * 60_000, slackMs: 92 * 60_000)
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            app.appearance = appearance
            let view = AquariumShell(tab: .day, paused: false, onTab: { _ in }, onSettings: {}, onPause: {}, onQuit: {}) {
                VStack(spacing: 0) {
                    AquariumNavigator(title: "10月17日 周六 (今日)", tab: .day, current: true, canGoNext: false, previous: {}, next: {}, back: {})
                    AquariumHabitat(summary: summary, paused: false, motionEnabled: false)
                    AquariumDaySummary(summary: summary)
                    VStack(spacing: 8) {
                        HStack { Text("时间去向"); Spacer(); Text("总计 4h 50m").monospacedDigit() }
                            .font(.system(size: 10)).foregroundStyle(AquariumStyle.muted)
                        block("工作", duration: "3h 18m", rows: [("Xcode", "1h 45m"), ("Figma", "1h 05m"), ("Terminal", "28m")], color: AquariumStyle.work)
                        block("摸鱼", duration: "1h 32m", rows: [("网页统计", "1h 08m"), ("微信", "24m")], color: AquariumStyle.leisure)
                    }.padding(.horizontal, 18).padding(.top, 4)
                    Spacer(minLength: 0)
                }
            }.environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.appearance = appearance
            let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 348, height: 460), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 348, height: 460)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = output.appendingPathComponent("static-day-\(dark ? "dark" : "light").png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            print(url.path)
            window.contentView = nil
        }
    }
    static func block(_ title: String, duration: String, rows: [(String, String)], color: Color) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title).foregroundStyle(AquariumStyle.muted)
                Spacer()
                Text(duration).bold().monospacedDigit()
            }.font(.system(size: 10.5)).frame(height: 20)
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Image(systemName: rows[i].0 == "网页统计" ? "globe" : "app.fill").foregroundStyle(color).frame(width: 22)
                    Text(rows[i].0).font(.system(size: 12))
                    if rows[i].0 == "网页统计" { Image(systemName: "chevron.right").font(.system(size: 8)) }
                    Spacer()
                    Image(systemName: "ellipsis").font(.system(size: 10)).foregroundStyle(AquariumStyle.muted)
                    Text(rows[i].1).font(.system(size: 11, weight: .semibold)).monospacedDigit().frame(width: 66, alignment: .trailing)
                }.frame(height: 32)
            }
        }
    }
}
