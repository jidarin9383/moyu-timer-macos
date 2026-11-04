import Foundation

enum VideoPageRules {
    static func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()

        if under(host, "miguvideo.com") {
            return path.hasPrefix("/p/live/") && path.count > "/p/live/".count
        }
        if host == "live.bilibili.com" { return hasContent(path) }
        if under(host, "bilibili.com") {
            return path.hasPrefix("/video/") || path.hasPrefix("/bangumi/play/")
        }
        if under(host, "youtube.com") {
            return path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
                || (path == "/watch" && URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name == "v" && !($0.value ?? "").isEmpty }) == true)
        }
        if under(host, "youtu.be") { return hasContent(path) }
        if host == "live.douyin.com" || host == "live.kuaishou.com" { return hasContent(path) }
        if under(host, "douyin.com") { return path.hasPrefix("/video/") }
        if under(host, "kuaishou.com") { return path.hasPrefix("/short-video/") }
        if under(host, "tiktok.com") { return path.contains("/video/") || path.hasSuffix("/live") }
        if under(host, "iqiyi.com") { return path.hasPrefix("/v_") }
        if host == "v.qq.com" { return path.hasPrefix("/x/cover/") || path.hasPrefix("/x/page/") }
        if under(host, "youku.com") { return path.hasPrefix("/v_show/") }
        if under(host, "mgtv.com") { return path.hasPrefix("/b/") }
        if under(host, "netflix.com") { return path.hasPrefix("/watch/") }
        if under(host, "instagram.com") { return path.hasPrefix("/reel/") }
        if under(host, "facebook.com") { return path.hasPrefix("/watch/") }
        if under(host, "weibo.com") { return path.hasPrefix("/tv/show/") }
        if under(host, "douyu.com") || under(host, "huya.com") {
            let components = path.split(separator: "/")
            return components.count == 1 && components[0].allSatisfy(\.isNumber)
        }
        if under(host, "twitch.tv") {
            let components = path.split(separator: "/")
            return components.count == 1 && !["directory", "search", "settings", "downloads", "subscriptions"]
                .contains(components[0])
        }
        return false
    }

    private static func under(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private static func hasContent(_ path: String) -> Bool {
        path.split(separator: "/").first != nil
    }
}
