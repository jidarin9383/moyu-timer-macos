import Cocoa

// 显式入口：不用 @main，确保 AppDelegate 一定被接上（AppKit 菜单栏 App 的经典写法）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
