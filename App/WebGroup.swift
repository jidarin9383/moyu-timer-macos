import Cocoa

/// 浏览器统一归组「网页统计」（PRD F7，v0.6 起交付）。
/// Chrome / Safari / Edge 等不再单独计时长，全部时间计入这一个虚拟组，
/// 组内按「域名」拆分停留时长（sessions.domain）。
enum WebGroup {
    /// 虚拟 App 行的 bundleId。刻意选用不可能与真实 App 冲突的值。
    static let bundleId = "moyu.webgroup.internal"
    static let name = "网页统计"

    /// The original migration scope stays fixed. Later browser additions retain
    /// their raw native records, which statistics exclude under the website-only policy.
    private static let legacyBrowsers: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave Browser",
        "com.operasoftware.Opera": "Opera",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "org.chromium.Chromium": "Chromium",
        "org.mozilla.firefox": ""          // Firefox uses Accessibility, not AppleScript URL commands.
    ]

    static var legacyBrowserBundleIds: [String] { legacyBrowsers.keys.sorted() }

    /// Bundle identifiers and URL interfaces were inspected in vendor app bundles.
    /// Unlisted applications remain native apps; no name-prefix matching is used.
    static let browsers: [String: String] = legacyBrowsers.merging([
        "com.tencent.qqbrowserappmac": "QQBrowser",
        "com.quark.desktop": "Quark",
        "net.qihoo.360browser": "360Chrome",
        "com.qihoo.litebrowserx": "", // Store edition: recognized, but no URL adapter yet.
        "company.thebrowser.dia": "Dia",
        "ai.perplexity.comet": "Comet",
        "com.kagi.kagimacOS": "Orion"
    ]) { existing, _ in existing }

    /// Safari and Orion expose current tab; the Chromium-family browsers expose active tab.
    static func urlQueryProperty(_ bundleId: String) -> String? {
        guard appleScriptAppName(bundleId) != nil else { return nil }
        return ["com.apple.Safari", "com.kagi.kagimacOS"].contains(bundleId)
            ? "URL of current tab of front window" : "URL of active tab of front window"
    }

    static func isBrowser(_ bundleId: String) -> Bool {
        browsers[bundleId] != nil
    }

    static func usesAccessibility(_ bundleId: String) -> Bool { bundleId == "org.mozilla.firefox" }

    static func supportsURLReading(_ bundleId: String) -> Bool {
        usesAccessibility(bundleId) || appleScriptAppName(bundleId) != nil
    }

    static func browserName(_ bundleId: String) -> String? {
        usesAccessibility(bundleId) ? "Firefox" : appleScriptAppName(bundleId)
    }

    /// 该浏览器能否通过 AppleScript 读网址。
    static func appleScriptAppName(_ bundleId: String) -> String? {
        guard let name = browsers[bundleId], !name.isEmpty else { return nil }
        return name
    }
}
