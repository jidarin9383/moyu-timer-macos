import Cocoa

/// 网址（域名）的内置分类规则（PRD F7 收官：b站→摸鱼、GitHub→工作）。
/// 与 App 级规则一致：命中「工作」算工作，命中「摸鱼」算摸鱼，未命中默认摸鱼。
/// 匹配支持子域名：规则 "bilibili.com" 命中 "www.bilibili.com"（按域名边界匹配，不会误伤 "mygithub.com"）。
/// 用户手动改过的域名（domains.is_custom=1）永远优先，不受这里影响。
enum DomainRules {
    static let workDomains: Set<String> = [
        // 代码 / 技术
        "github.com", "gitlab.com", "gitee.com", "coding.net",
        "stackoverflow.com", "stackexchange.com", "serverfault.com",
        "developer.apple.com", "developer.android.com", "swift.org", "kotlinlang.org",
        "npmjs.com", "pypi.org", "mvnrepository.com", "cocoapods.org",
        // 文档 / 协作
        "notion.so", "feishu.cn", "larksuite.com", "docs.qq.com",
        "doc.weixin.qq.com", "shimo.im", "yuque.com", "wolai.com",
        "figma.com", "mastergo.com", "js.design",
        "trello.com", "asana.com", "linear.app", "monday.com",
        "atlassian.net", "tapd.cn", "worktile.com", "teambition.com", "tower.im",
        // 会议 / 邮件
        "meeting.tencent.com", "voovmeeting.com", "zoom.us",
        "mail.qq.com", "mail.163.com", "outlook.live.com", "mail.google.com",
        // 云 / 运维 / 网盘
        "console.cloud.tencent.com", "console.aliyun.com", "console.cloud.baidu.com",
        "cloud.tencent.com", "cloud.baidu.com", "vercel.com", "netlify.com",
        "pan.baidu.com", "aliyundrive.com", "weiyun.com",
    ]

    static let slackDomains: Set<String> = [
        // 视频 / 直播
        "bilibili.com", "youtube.com", "iqiyi.com", "v.qq.com", "youku.com",
        "mgtv.com", "le.com", "netflix.com", "douyu.com", "huya.com",
        // 社交 / 社区
        "weibo.com", "zhihu.com", "douyin.com", "xiaohongshu.com", "kuaishou.com",
        "x.com", "twitter.com", "facebook.com", "instagram.com", "reddit.com",
        "tieba.baidu.com", "tiktok.com",
        // 音乐
        "music.163.com", "y.qq.com", "kugou.com", "kuwo.cn",
        // 购物
        "taobao.com", "tmall.com", "jd.com", "pinduoduo.com", "smzdm.com",
        // 游戏
        "steampowered.com", "steamcommunity.com",
        // 资讯
        "toutiao.com", "36kr.com", "sspai.com", "ifanr.com",
    ]

    /// 判定域名分类；空域名返回 nil（由调用方回落到 App 级分类）。
    static func category(domain: String) -> AppCategory? {
        let d = domain.lowercased()
        guard !d.isEmpty else { return nil }
        if matches(d, in: workDomains) { return .work }
        if matches(d, in: slackDomains) { return .slack }
        return .slack   // 与 App 级一致：未命中默认摸鱼
    }

    /// 域名边界匹配：整等或为其子域名（"www.bilibili.com" 命中 "bilibili.com"，
    /// 但 "mygithub.com" 不命中 "github.com"）。
    private static func matches(_ domain: String, in rules: Set<String>) -> Bool {
        for rule in rules where domain == rule || domain.hasSuffix("." + rule) {
            return true
        }
        return false
    }
}
