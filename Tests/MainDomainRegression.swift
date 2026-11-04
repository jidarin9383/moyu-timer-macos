import Foundation

@main
struct MainDomainRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoyuDomains-\(UUID())")
        setenv("MOYU_DB_DIR", directory.path, 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store()
        let start = DayRange.localCalendar.startOfDay(for: Date()).addingTimeInterval(60)
        let range = DayRange.day(start)
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "PASS" : "FAIL") \(description)")
            if !condition { failures += 1 }
        }
        let examples = [
            ("docs.google.com", "google.com"),
            ("API.Example.COM.", "example.com"),
            ("news.example.com.cn", "example.com.cn"),
            ("news.example.co.uk", "example.co.uk"),
            ("foo.example.com.au", "example.com.au"),
            ("forum.city.kawasaki.jp", "city.kawasaki.jp"),
            ("a.b.ck", "a.b.ck"),
            ("forums.www.ck", "www.ck"),
            ("tenant.vercel.app", "vercel.app"),
            ("127.0.0.1", "127.0.0.1"),
            ("[::1]", "[::1]"),
            ("localhost", "localhost"),
            ("google.com.evil.net", "evil.net")
        ]
        for (host, expected) in examples {
            check(WebsiteDomain.mainDomain(host) == expected, "main domain: \(host) → \(expected)")
        }
        let internationalRoot = URL(string: "https://食狮.公司.cn")!.host!
        check(WebsiteDomain.mainDomain("www.食狮.公司.cn") == internationalRoot,
              "internationalized suffixes and hosts normalize consistently")
        func record(_ domain: String, seconds: Int) {
            let session = store.openSession(bundleId: WebGroup.bundleId, name: WebGroup.name,
                                            domain: domain, start: start)
            store.closeSession(rowId: session.rowId, endTs: Int(start.timeIntervalSince1970) + seconds)
        }
        record("docs.github.com", seconds: 12)
        record("api.github.com", seconds: 8)
        record("docs.qq.com", seconds: 7)
        record("v.qq.com", seconds: 3)
        let appId = store.appId(bundleId: WebGroup.bundleId)!
        let rows = store.domainUsage(appId: appId, from: range.start, to: range.end)
        check(rows.filter { $0.domain == "github.com" }.map(\.ms) == [20_000],
              "historical subdomains aggregate under their main domain")
        check(rows.filter { $0.domain == "qq.com" && $0.category == .work }.map(\.ms) == [7_000],
              "main-domain grouping preserves existing work classification")
        check(rows.filter { $0.domain == "qq.com" && $0.category == .slack }.map(\.ms) == [3_000],
              "main-domain grouping preserves existing leisure classification")
        check(Set(rows.map(\.id)).count == rows.count, "grouped row identities remain unique across categories")
        check(rows.reduce(0) { $0 + $1.ms } == 30_000, "domain grouping preserves total duration")
        store.setDomainCategory(domain: "qq.com", category: .work)
        let changed = store.domainUsage(appId: appId, from: range.start, to: range.end)
        check(changed.filter { $0.domain == "qq.com" && $0.category == .work }.map(\.ms) == [10_000],
              "editing a main domain reclassifies all historical subdomains")
        record("new.qq.com", seconds: 5)
        check(store.domainCategory("new.qq.com") == .work,
              "future subdomains inherit the main domain's custom category")
        store.setDomainCategory(domain: "qq.com", category: .ignored)
        check(store.categoryTotals(from: range.start, to: range.end)[.ignored] == 15_000,
              "ignoring a main domain reconciles totals with its subdomains")
        check(store.categoryTotals(from: range.start, to: range.end)[.work] == 20_000,
              "main-domain edits do not affect unrelated domains")
        check(store.sessions(appId: appId, from: range.start, to: range.end).count == 5,
              "grouping preserves original session records")
        if failures > 0 { exit(1) }
    }
}
