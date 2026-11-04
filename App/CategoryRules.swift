import Cocoa
import SwiftUI

/// App 的三种分类归属。rawValue 与数据库存储值一一对应，不要随意改。
/// v0.5 起取消「未分类」：未命中内置规则的 App 默认算摸鱼；「已忽略」不计入任何统计。
enum AppCategory: String, CaseIterable, Identifiable {
    case work = "work"
    case slack = "slack"
    case ignored = "ignored"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: return "工作"
        case .slack: return "摸鱼"
        case .ignored: return "已忽略"
        }
    }

    /// 语义色（v1.0 设计系统，深色模式自动切换）：
    /// Work = teal; leisure = orange; ignored = neutral.
    var color: Color {
        switch self {
        case .work: return Palette.work
        case .slack: return Palette.slack
        case .ignored: return Palette.ignored
        }
    }

    /// 强调文字色（块总时长等需要更深一点的位置）。
    var deepColor: Color {
        switch self {
        case .work: return Palette.workDeep
        case .slack: return Palette.slackDeep
        case .ignored: return Palette.ink2
        }
    }

    var tintColor: Color {
        switch self {
        case .work: return Palette.workTint
        case .slack: return Palette.slackTint
        case .ignored: return Palette.track
        }
    }

    /// 右键菜单里「移到××」用的 SF Symbol。
    var menuSymbol: String {
        switch self {
        case .work: return "briefcase"
        case .slack: return "fish"
        case .ignored: return "eye.slash"
        }
    }

    init(dbValue: String) {
        // 旧库里的 'none'（已取消的「未分类」状态）按现行规则一律算摸鱼
        if dbValue == "none" { self = .slack; return }
        self = AppCategory(rawValue: dbValue) ?? .slack
    }
}

/// 内置默认分类规则（PRD 附录 A）。
/// 匹配顺序：bundleId 精确 → bundleId 前缀 → App 名称关键词；都不中则「摸鱼」。
/// 用户手动改过的分类（is_custom=1）永远优先，不受这里影响。
enum CategoryRules {
    private static let workBundleIds: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.atom",
        "com.sublimetext.3",
        "com.sublimetext.4",
        "com.apple.Mail",
        "com.apple.iCal",
        "com.apple.reminders",
        "com.apple.Notes",
        "com.apple.iWork.Keynote",
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.PowerPoint",
        "com.microsoft.onenote.mac",
        "com.tinyspeck.slackmacapp",
        "us.zoom.xos",
        "com.tencent.meeting",
        "com.postmanlabs.mac",
        "notion.id",
        "md.obsidian",
        "com.raycast.macos",
        "com.1password.1password",
        "com.flexibits.fantastical2.mac",
        "com.culturedcode.ThingsMac",
        "com.readdle.spark.macos",
        "com.docker.docker",
        "com.google.android.studio",
    ]

    /// 前缀匹配，覆盖同厂商全家桶（JetBrains 全系算工作）。
    private static let workBundlePrefixes: [String] = [
        "com.jetbrains.",
    ]

    private static let slackBundleIds: Set<String> = [
        "com.valvesoftware.steam",
        "com.netease.163music",
    ]

    private static let slackNameKeywords: [String] = [
        "哔哩哔哩", "Bilibili", "bilibili",
        "微博", "Weibo",
        "抖音", "TikTok",
        "小红书",
        "淘宝", "Taobao", "天猫",
        "京东",
        "爱奇艺", "iQiyi",
        "腾讯视频", "优酷", "Youku",
        "网易云音乐", "QQ音乐",
        "Steam",
        "YouTube",
        "知乎",
        "斗鱼", "虎牙",
        "游戏", "Game",
    ]

    private static let workNameKeywords: [String] = [
        "Xcode", "Code", "Visual Studio", "Studio", "Cursor",
        "Terminal", "iTerm", "Warp",
        "Figma", "Sketch", "Photoshop", "Illustrator", "Premiere",
        "Postman", "Notion", "Obsidian", "Slack", "Zoom",
        "Mail", "日历", "备忘录", "提醒事项",
        "Keynote", "Pages", "Numbers",
        "Word", "Excel", "PowerPoint", "OneNote",
        "腾讯会议", "飞书", "Lark", "钉钉", "DingTalk", "企业微信",
        "GitHub", "Git", "Docker",
        "Simulator", "Instruments",
    ]

    /// 注意：浏览器（Safari/Chrome/Edge/Arc/Firefox…）、微信、访达等不命中规则的 App
    /// 按产品决策（v0.5）默认算「摸鱼」，用户可一键移到工作或忽略；
    /// v0.7 起浏览器已按域名进一步细分（见 DomainRules.swift），这里是 App 级兜底。
    static func category(bundleId: String?, name: String?) -> AppCategory {
        if let bundleId {
            if workBundleIds.contains(bundleId) { return .work }
            if slackBundleIds.contains(bundleId) { return .slack }
            if workBundlePrefixes.contains(where: { bundleId.hasPrefix($0) }) { return .work }
        }
        let name = name ?? ""
        if slackNameKeywords.contains(where: { name.contains($0) }) { return .slack }
        if workNameKeywords.contains(where: { name.contains($0) }) { return .work }
        return .slack   // v0.5：不再有「未分类」，默认一律算摸鱼
    }
}
