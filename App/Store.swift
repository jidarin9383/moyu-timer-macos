import Cocoa
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 数据模型

struct AppUsageRow: Identifiable, Equatable {
    var id: String { "\(appId)-\(category.rawValue)" }
    let appId: Int64
    let bundleId: String
    let name: String
    let category: AppCategory
    var ms: Int
}

struct DayCategoryUsage: Identifiable, Equatable {
    var id: String { "\(dayStart)-\(category.rawValue)" }
    let dayStart: Int   // 当地零点的 Unix 秒
    let category: AppCategory
    let ms: Int
}

struct SessionRow: Identifiable {
    let id = UUID()
    let startTs: Int
    let endTs: Int
    let durationMs: Int
}

/// 「网页统计」组内单个域名的停留时长（行内展开列表用）。
/// category 为该域名的有效分类：域名表有行 → 域名分类，否则回落整组分类。
/// 只收录成功读到网址的域名；读不到网址的时段不计入（见 uncountedWebMs）。
struct DomainUsageRow: Identifiable {
    var id: String { "\(domain)-\(category.rawValue)" }
    let domain: String
    let ms: Int
    let category: AppCategory
}

/// 采集器持有的「打开中会话」。start 为实际开始时间（合并续接时为上一段的开始时间）。
/// domain 非空表示这是「网页统计」组内按域名拆分的一段（bundleId 为 WebGroup.bundleId）。
struct OpenSession {
    let rowId: Int64
    let appId: Int64
    let bundleId: String
    var start: Date
    var lastFlush: Date
    var domain: String?
    var isVideoPage = false
}

// MARK: - 日期区间（周一为一周起点，PRD：周视图周一起）

enum DayRange {
    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }

    static func day(_ date: Date) -> (start: Int, end: Int) {
        let cal = localCalendar
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }

    static func week(_ date: Date) -> (start: Int, end: Int) {
        let cal = localCalendar
        let startOfToday = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: startOfToday)   // 1 = 周日
        let daysSinceMonday = (weekday + 5) % 7
        let monday = cal.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday)!
        let nextMonday = cal.date(byAdding: .day, value: 7, to: monday)!
        return (Int(monday.timeIntervalSince1970), Int(nextMonday.timeIntervalSince1970))
    }

    static func month(_ date: Date) -> (start: Int, end: Int) {
        let cal = localCalendar
        let comps = cal.dateComponents([.year, .month], from: date)
        let start = cal.date(from: comps)!
        let end = cal.date(byAdding: DateComponents(month: 1), to: start)!
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }

    /// ts 之后的下一个本地零点（跨天切分用）。
    static func nextLocalMidnight(after ts: Int) -> Int {
        let cal = localCalendar
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts)))
        if let next = cal.date(byAdding: .day, value: 1, to: start) {
            return Int(next.timeIntervalSince1970)
        }
        return ts + 86400
    }
}

// MARK: - 存储层

/// 系统 SQLite3 直连（零第三方依赖）。
/// v1 所有调用都发生在主线程（采集定时器与 UI 刷新均挂主 RunLoop），无需并发队列。
final class Store {
    private var db: OpaquePointer?
    private(set) var revision: UInt64 = 0

    /// 分类/域名分类被用户修改后触发（v0.9）：StatsViewModel 订阅它即时重建快照，
    /// 不必等下一次周期刷新。始终回主线程调用。
    var onChange: (() -> Void)?

    private func notifyChange() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }
    let databaseURL: URL

    init() throws {
        // 测试/调试可用 MOYU_DB_DIR 覆盖数据目录；正常使用不设该变量，走默认路径
        let base = ProcessInfo.processInfo.environment["MOYU_DB_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MoyuTimer", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        databaseURL = dir.appendingPathComponent("moyu.sqlite")

        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if db != nil { sqlite3_close(db) }
            throw NSError(domain: "Store", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "打开数据库失败: \(msg)"])
        }
        try exec(schemaSQL)
        // v0.5 迁移：取消「未分类」状态，历史 'none' 一律按摸鱼计（新装库无此行，无副作用）
        try? exec("UPDATE apps SET category = 'slack' WHERE category = 'none'")
        // v0.6 迁移：浏览器统一归组「网页统计」——不再给 Chrome/Safari 等单独计时长
        migrateBrowsersToWebGroup()
        // v0.7 迁移：为历史会话里出现过的域名建立规则行（按内置规则归类，之后统计即时拆分）
        migrateDomains()
    }

    /// 会话的有效分类：有域名且域名已归类 → 域名分类；否则回落 App 分类。
    /// 「(历史浏览)」与无域名（读取失败）都走 App 级分类。
    /// 分类不冗余存进会话，统计时实时计算 → 改域名/App 分类，历史即时重算。
    private let effectiveCategorySQL = """
        CASE WHEN s.domain IS NOT NULL AND s.domain != '' AND d.category IS NOT NULL
             THEN d.category ELSE a.category END
        """
    private let domainJoinSQL = "LEFT JOIN domains d ON d.domain = s.domain"

    /// 网页时长只统计「成功读到网址」的段（用户决策 v0.8）：
    /// 读不到网址（未授权 / 查询失败 / 网址接口不可用）的网页时段
    /// 不计入任何统计；「(历史浏览)」是旧数据迁移桶，同样无法归因，一并排除。
    /// Recognized browser apps never contribute a separate native-app row or total,
    /// including records captured before their URL adapter was added. Keep raw history intact.
    private let webCountableSQL = """
        NOT (s.kind = 'web' AND (s.domain IS NULL OR s.domain = '' OR s.domain = '(历史浏览)'))
        AND a.bundle_id NOT IN (\(WebGroup.browsers.keys.sorted().map { "'\($0)'" }.joined(separator: ",")))
        """

    /// 把历史浏览器会话划归「网页统计」组。旧数据没有域名记录，
    /// domain 置为「(历史浏览)」标记，与「未能读取网址」（新数据读不到）区分开。
    /// 若用户曾把某个浏览器手动分成工作/摸鱼/忽略，把最近一次的手动分类带到组上，保留用户意图。
    private func migrateBrowsersToWebGroup() {
        let webGroupId = upsertApp(bundleId: WebGroup.bundleId, name: WebGroup.name)
        guard webGroupId > 0 else { return }

        let browserIds = WebGroup.legacyBrowserBundleIds.map { "'\($0)'" }.joined(separator: ",")
        do {
            try update("""
                UPDATE sessions SET app_id = ?, kind = 'web', domain = '(历史浏览)'
                WHERE app_id IN (SELECT id FROM apps WHERE bundle_id IN (\(browserIds)))
                """, [webGroupId])
            // 注意：update() 的返回值是 last_insert_rowid（给 INSERT 用的），
            // 受影响行数必须用 sqlite3_changes 取（v0.7 修：此前日志里的段数是假的）
            let count = sqlite3_changes(db)
            if count > 0 {
                print("[Store] 已将 \(count) 段浏览器会话划归「网页统计」")
            }
        } catch {
            print("[Store] 浏览器归组迁移失败: \(error.localizedDescription)")
        }

        // 继承用户对浏览器的手动分类（取最近一次修改的）。
        // 但用户若手动改过「网页统计」组自己的分类（is_custom=1），以用户的组选择为准——
        // 否则每次重启都会拿浏览器旧分类覆盖掉用户对组的修改（v0.7 修）。
        guard !appIsCustom(webGroupId) else { return }
        if let stmt = try? prepare("""
            SELECT category FROM apps
            WHERE bundle_id IN (\(browserIds)) AND is_custom = 1
            ORDER BY updated_at DESC LIMIT 1
            """) {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                let category = columnText(stmt, 0)
                do {
                    try update("UPDATE apps SET category = ?, is_custom = 1, updated_at = ? WHERE id = ?",
                               [category, Int(Date().timeIntervalSince1970), webGroupId])
                    print("[Store] 网页统计组继承浏览器手动分类: \(category)")
                } catch {
                    print("[Store] 继承分类失败: \(error.localizedDescription)")
                }
            }
        }
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    private let schemaSQL = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS apps (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            bundle_id  TEXT UNIQUE NOT NULL,
            name       TEXT NOT NULL,
            category   TEXT NOT NULL DEFAULT 'slack',
            is_custom  INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id      INTEGER NOT NULL REFERENCES apps(id),
            domain      TEXT,
            kind        TEXT NOT NULL DEFAULT 'app',
            start_ts    INTEGER NOT NULL,
            end_ts      INTEGER NOT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            is_open     INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS domains (
            domain     TEXT PRIMARY KEY,
            category   TEXT NOT NULL DEFAULT 'slack',
            is_custom  INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_app ON sessions(app_id, start_ts);
        CREATE INDEX IF NOT EXISTS idx_sessions_start ON sessions(start_ts);
        """

    // MARK: - 底层执行

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        defer { if let err { sqlite3_free(err) } }
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) }
                ?? db.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown"
            throw NSError(domain: "Store", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "SQL 执行失败: \(msg)"])
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NSError(domain: "Store", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "SQL 准备失败: \(msg)"])
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }

    @discardableResult
    private func update(_ sql: String, _ values: [Any]) throws -> Int64 {
        guard let stmt = try prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in values.enumerated() {
            switch v {
            case let x as Int:   bind(stmt, Int32(i + 1), x)
            case let x as Int64: bind(stmt, Int32(i + 1), x)
            case let x as String: bind(stmt, Int32(i + 1), x)
            case is NSNull:      sqlite3_bind_null(stmt, Int32(i + 1))
            default:
                try finalizeAndThrow(stmt, "不支持的绑定类型")
            }
        }
        if sqlite3_step(stmt) != SQLITE_DONE {
            try finalizeAndThrow(stmt, "SQL 更新失败")
        }
        if sqlite3_changes(db) > 0 { revision &+= 1 }
        return sqlite3_last_insert_rowid(db)
    }

    private func finalizeAndThrow(_ stmt: OpaquePointer?, _ message: String) throws -> Never {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_finalize(stmt)
        throw NSError(domain: "Store", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "\(message): \(msg)"])
    }

    // MARK: - Apps 与分类

    /// 插入或更新 App；新 App 按内置规则给初始分类。返回 app id。
    func upsertApp(bundleId: String, name: String) -> Int64 {
        let category = CategoryRules.category(bundleId: bundleId, name: name).rawValue
        let now = Int(Date().timeIntervalSince1970)
        do {
            try update("""
                INSERT INTO apps(bundle_id, name, category, is_custom, updated_at)
                VALUES(?, ?, ?, 0, ?)
                ON CONFLICT(bundle_id) DO UPDATE SET name = excluded.name
                """, [bundleId, name, category, now])
        } catch {
            print("[Store] upsertApp 失败: \(error.localizedDescription)")
        }
        guard let stmt = try? prepare("SELECT id FROM apps WHERE bundle_id = ?") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, bundleId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return 0
    }

    func category(ofAppId appId: Int64) -> AppCategory {
        guard let stmt = try? prepare("SELECT category FROM apps WHERE id = ?") else { return .slack }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, appId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return AppCategory(dbValue: columnText(stmt, 0))
        }
        return .slack
    }

    /// 该 App 行是否被用户手动改过分类（is_custom=1）。
    private func appIsCustom(_ appId: Int64) -> Bool {
        guard let stmt = try? prepare("SELECT is_custom FROM apps WHERE id = ?") else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, appId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0) != 0
        }
        return false
    }

    func setCategory(appId: Int64, category: AppCategory) {
        do {
            try update("UPDATE apps SET category = ?, is_custom = 1, updated_at = ? WHERE id = ?",
                       [category.rawValue, Int(Date().timeIntervalSince1970), appId])
            notifyChange()
        } catch {
            print("[Store] setCategory 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 域名与分类（PRD F7：网页统计组内按域名拆分工作/摸鱼）

    /// 确保域名在 rules 表里：首次见到按内置规则归类；用户改过的原样保留。
    @discardableResult
    func upsertDomain(_ domain: String) -> AppCategory {
        let mainDomain = WebsiteDomain.mainDomain(domain)
        if mainDomain != domain, let category = customDomainCategory(mainDomain) {
            // Keep the stored alias in sync so SQL totals and live usage agree.
            if domainCategory(domain) != category {
                setStoredDomainCategory(domain, category: category)
            }
            return category
        }
        if let existing = domainCategory(domain) { return existing }
        let category = DomainRules.category(domain: domain) ?? .slack
        do {
            try update("""
                INSERT INTO domains(domain, category, is_custom, updated_at)
                VALUES(?, ?, 0, ?)
                ON CONFLICT(domain) DO NOTHING
                """, [domain, category.rawValue, Int(Date().timeIntervalSince1970)])
        } catch {
            print("[Store] upsertDomain 失败: \(error.localizedDescription)")
        }
        return domainCategory(domain) ?? category
    }

    func domainCategory(_ domain: String) -> AppCategory? {
        guard let stmt = try? prepare("SELECT category FROM domains WHERE domain = ?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, domain)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return AppCategory(dbValue: columnText(stmt, 0))
        }
        return nil
    }

    private func customDomainCategory(_ domain: String) -> AppCategory? {
        guard let stmt = try? prepare("SELECT category FROM domains WHERE domain = ? AND is_custom = 1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, domain)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return AppCategory(dbValue: columnText(stmt, 0))
    }

    private func setStoredDomainCategory(_ domain: String, category: AppCategory) {
        do {
            try writeDomainCategory(domain, category: category)
        } catch {
            print("[Store] domain category update failed: \(error.localizedDescription)")
        }
    }

    private func writeDomainCategory(_ domain: String, category: AppCategory) throws {
        try update("""
            INSERT INTO domains(domain, category, is_custom, updated_at)
            VALUES(?, ?, 1, ?)
            ON CONFLICT(domain) DO UPDATE SET
                category = excluded.category, is_custom = 1, updated_at = excluded.updated_at
            """, [domain, category.rawValue, Int(Date().timeIntervalSince1970)])
    }

    /// A main-domain edit applies to existing aliases and is inherited by future ones.
    func setDomainCategory(domain: String, category: AppCategory) {
        let mainDomain = WebsiteDomain.mainDomain(domain)
        var aliases: Set<String> = [mainDomain]
        guard let stmt = try? prepare("SELECT domain FROM domains") else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let alias = columnText(stmt, 0)
            if WebsiteDomain.mainDomain(alias) == mainDomain { aliases.insert(alias) }
        }
        sqlite3_finalize(stmt)
        do {
            try exec("BEGIN IMMEDIATE")
            for alias in aliases { try writeDomainCategory(alias, category: category) }
            try exec("COMMIT")
            notifyChange()
        } catch {
            try? exec("ROLLBACK")
            print("[Store] setDomainCategory failed: \(error.localizedDescription)")
        }
    }

    /// 为历史会话里出现过的域名补建规则行（v0.7 迁移）。
    /// 「(历史浏览)」刻意排除：它是旧数据的时间桶，不是真实网址，按整组分类计。
    private func migrateDomains() {
        var domains: [String] = []
        guard let stmt = try? prepare("""
            SELECT DISTINCT domain FROM sessions
            WHERE domain IS NOT NULL AND domain != '' AND domain != '(历史浏览)'
            """) else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            domains.append(columnText(stmt, 0))
        }
        for d in domains { upsertDomain(d) }
        if !domains.isEmpty {
            print("[Store] 已为 \(domains.count) 个历史域名建立分类规则")
        }
    }

    // MARK: - 会话

    /// Open a new raw interval. Only exactly adjacent intervals may share a row;
    /// a stored row must never include unobserved time between two foreground uses.
    /// domain 非空 = 「网页统计」组内按域名拆分的一段（此类会话不做防抖合并：
    /// 切换域名是主动行为，且合并会与中间那段双重计时）。
    func openSession(bundleId: String, name: String, domain: String? = nil,
                     start: Date) -> OpenSession {
        let appId = upsertApp(bundleId: bundleId, name: name)
        let startTs = Int(start.timeIntervalSince1970)
        let isWeb = bundleId == WebGroup.bundleId
        let kind = isWeb ? "web" : "app"
        if let domain, !domain.isEmpty, isWeb {
            upsertDomain(domain)   // 首次见到按内置规则归类（b站→摸鱼、GitHub→工作）
        }

        if !isWeb, let prev = findMergeable(appId: appId, startTs: startTs) {
            do {
                // 续接：保留原开始时间，把上一段的时长补到续接点，再重新标记为打开中
                try update("UPDATE sessions SET is_open = 1, end_ts = ?, duration_ms = (? - start_ts) * 1000 WHERE id = ?",
                           [startTs, startTs, prev.rowId])
            } catch {
                print("[Store] 会话续接失败: \(error.localizedDescription)")
            }
            return OpenSession(rowId: prev.rowId, appId: appId, bundleId: bundleId,
                               start: Date(timeIntervalSince1970: TimeInterval(prev.startTs)),
                               lastFlush: start, domain: nil)
        }

        do {
            let rowId = try update("""
                INSERT INTO sessions(app_id, domain, kind, start_ts, end_ts, duration_ms, is_open)
                VALUES(?, ?, ?, ?, ?, 0, 1)
                """, [appId, domain ?? NSNull(), kind, startTs, startTs])
            return OpenSession(rowId: rowId, appId: appId, bundleId: bundleId,
                               start: start, lastFlush: start, domain: domain)
        } catch {
            print("[Store] openSession 失败: \(error.localizedDescription)")
            return OpenSession(rowId: 0, appId: appId, bundleId: bundleId,
                               start: start, lastFlush: start, domain: domain)
        }
    }

    private func findMergeable(appId: Int64, startTs: Int) -> (rowId: Int64, startTs: Int)? {
        // Exact adjacency preserves a continuous raw interval without filling a
        // lock, sleep, idle, or popover gap. Same-day matching prevents rollover merges.
        guard let stmt = try? prepare("""
            SELECT id, start_ts FROM sessions
            WHERE app_id = ? AND is_open = 0 AND end_ts = ?
              AND strftime('%Y-%m-%d', start_ts, 'unixepoch', 'localtime')
                = strftime('%Y-%m-%d', ?, 'unixepoch', 'localtime')
            ORDER BY end_ts DESC LIMIT 1
            """) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, appId)
        bind(stmt, 2, startTs)
        bind(stmt, 3, startTs)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let prevStart = Int(sqlite3_column_int64(stmt, 1))
            // 防重叠（v0.8 修，计划 3.1）：续接会把上一段拉长到当前时刻，
            // 若这中间记录过别的 App/网页，两个 App 会拿到同一段时间（合计超过墙钟时间）。
            // 只要候选段的 [start, now] 区间内存在任何其他会话，就不合并、新开一段。
            if hasInterveningSession(excludeRowId: rowId, from: prevStart, to: startTs) {
                return nil
            }
            return (rowId, prevStart)
        }
        return nil
    }

    /// [from, to) 区间内是否存在除 excludeRowId 之外的会话（含打开中的）。
    private func hasInterveningSession(excludeRowId: Int64, from: Int, to: Int) -> Bool {
        guard let stmt = try? prepare("""
            SELECT 1 FROM sessions
            WHERE id != ? AND start_ts < ? AND end_ts > ?
            LIMIT 1
            """) else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, excludeRowId)
        bind(stmt, 2, to)
        bind(stmt, 3, from)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func flushSession(rowId: Int64, endTs: Int) {
        do {
            // 注意：duration 必须用参数里的新 endTs 算，不能引用 SET 左侧的 end_ts（那是旧值）
            try update("""
                UPDATE sessions SET end_ts = ?, duration_ms = (? - start_ts) * 1000
                WHERE id = ? AND is_open = 1
                """, [endTs, endTs, rowId])
        } catch {
            print("[Store] flushSession 失败: \(error.localizedDescription)")
        }
    }

    /// 结算一段会话，跨越本地零点时按天拆成多行（PRD：跨天会话按 00:00 切分）。
    func closeSession(rowId: Int64, endTs: Int) {
        guard let row = selectSession(rowId) else { return }
        var cursor = row.startTs
        var isFirst = true
        while cursor < endTs {
            let dayEnd = DayRange.nextLocalMidnight(after: cursor)
            let segEnd = min(dayEnd, endTs)
            if segEnd <= cursor { break }
            let durationMs = (segEnd - cursor) * 1000
            do {
                if isFirst {
                    try update("UPDATE sessions SET end_ts = ?, duration_ms = ?, is_open = 0 WHERE id = ?",
                               [segEnd, durationMs, rowId])
                    isFirst = false
                } else {
                    // 跨午夜的新段必须继承原行的 domain/kind，
                    // 否则浏览器会话过了零点会丢域名、错分类（v0.7 修）
                    try update("""
                        INSERT INTO sessions(app_id, domain, kind, start_ts, end_ts, duration_ms, is_open)
                        VALUES(?, ?, ?, ?, ?, ?, 0)
                        """, [row.appId, row.domain ?? NSNull(), row.kind, cursor, segEnd, durationMs])
                }
            } catch {
                print("[Store] closeSession 失败: \(error.localizedDescription)")
                return
            }
            cursor = segEnd
        }
        if isFirst {
            // endTs <= startTs 的异常情况（时钟回跳等）：原样关闭
            do {
                try update("UPDATE sessions SET is_open = 0 WHERE id = ?", [rowId])
            } catch {
                print("[Store] closeSession 兜底失败: \(error.localizedDescription)")
            }
        }
    }

    private func selectSession(_ rowId: Int64) -> (appId: Int64, startTs: Int, domain: String?, kind: String)? {
        guard let stmt = try? prepare("SELECT app_id, start_ts, domain, kind FROM sessions WHERE id = ?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, rowId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let domain = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : columnText(stmt, 2)
            return (sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int64(stmt, 1)),
                    domain, columnText(stmt, 3))
        }
        return nil
    }

    /// 上次异常退出遗留的「打开中」会话直接结算（最多丢失一个落盘周期 15s）。
    func recoverOpenSessions() {
        do {
            try update("UPDATE sessions SET is_open = 0 WHERE is_open = 1", [])
        } catch {
            print("[Store] recoverOpenSessions 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 统计查询

    func categoryTotals(from: Int, to: Int) -> [AppCategory: Int] {
        var result: [AppCategory: Int] = [:]
        guard let stmt = try? prepare("""
            SELECT \(effectiveCategorySQL), SUM(s.duration_ms) FROM sessions s
            JOIN apps a ON a.id = s.app_id
            \(domainJoinSQL)
            WHERE s.start_ts >= ? AND s.start_ts < ? AND \(webCountableSQL)
            GROUP BY \(effectiveCategorySQL)
            """) else { return result }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, from)
        bind(stmt, 2, to)
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[AppCategory(dbValue: columnText(stmt, 0))] = Int(sqlite3_column_int64(stmt, 1))
        }
        return result
    }

    /// 按 (App × 有效分类) 汇总。「网页统计」组会按域名拆成多行
    /// （工作块一个、摸鱼块一个、已忽略块一个），普通 App 只有一行。
    func appUsage(from: Int, to: Int, limit: Int = 0) -> [AppUsageRow] {
        var result: [AppUsageRow] = []
        let sql = """
            SELECT s.app_id, a.bundle_id, a.name, \(effectiveCategorySQL), SUM(s.duration_ms) AS total
            FROM sessions s JOIN apps a ON a.id = s.app_id
            \(domainJoinSQL)
            WHERE s.start_ts >= ? AND s.start_ts < ? AND \(webCountableSQL)
            GROUP BY s.app_id, \(effectiveCategorySQL)
            ORDER BY total DESC
            """ + (limit > 0 ? " LIMIT \(limit)" : "")
        guard let stmt = try? prepare(sql) else { return result }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, from)
        bind(stmt, 2, to)
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(AppUsageRow(
                appId: sqlite3_column_int64(stmt, 0),
                bundleId: columnText(stmt, 1),
                name: columnText(stmt, 2),
                category: AppCategory(dbValue: columnText(stmt, 3)),
                ms: Int(sqlite3_column_int64(stmt, 4))
            ))
        }
        return result
    }

    /// 「网页统计」组内按域名的停留时长（降序），附带每个域名的有效分类
    /// （域名表有行 → 域名分类；否则回落整组分类，保证展开列表与行时长对得上）。
    /// 只返回「成功读到网址」的域名：读不到网址的时段不计入，另行用
    /// uncountedWebMs 透明展示，不混进本列表。
    func domainUsage(appId: Int64, from: Int, to: Int) -> [DomainUsageRow] {
        var result: [String: DomainUsageRow] = [:]
        guard let stmt = try? prepare("""
            SELECT s.domain, SUM(s.duration_ms) AS total,
                   COALESCE((SELECT dm.category FROM domains dm WHERE dm.domain = s.domain),
                            (SELECT a2.category FROM apps a2 WHERE a2.id = s.app_id))
            FROM sessions s
            WHERE s.app_id = ? AND s.start_ts >= ? AND s.start_ts < ?
              AND s.domain IS NOT NULL AND s.domain != '' AND s.domain != '(历史浏览)'
            GROUP BY s.domain
            ORDER BY total DESC
            """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, appId)
        bind(stmt, 2, from)
        bind(stmt, 3, to)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let domain = WebsiteDomain.mainDomain(columnText(stmt, 0))
            let category = AppCategory(dbValue: columnText(stmt, 2))
            let key = "\(domain)-\(category.rawValue)"
            result[key] = DomainUsageRow(domain: domain,
                ms: (result[key]?.ms ?? 0) + Int(sqlite3_column_int64(stmt, 1)), category: category)
        }
        return result.values.sorted {
            if $0.ms != $1.ms { return $0.ms > $1.ms }
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    /// 该区间内「未能读到网址」的网页时长（不计入统计，仅在展开区透明展示）。
    func uncountedWebMs(appId: Int64, from: Int, to: Int) -> Int {
        guard let stmt = try? prepare("""
            SELECT COALESCE(SUM(s.duration_ms), 0) FROM sessions s
            WHERE s.app_id = ? AND s.start_ts >= ? AND s.start_ts < ?
              AND s.kind = 'web'
              AND (s.domain IS NULL OR s.domain = '' OR s.domain = '(历史浏览)')
            """) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, appId)
        bind(stmt, 2, from)
        bind(stmt, 3, to)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    /// bundleId → app id（不存在返回 nil）。
    func appId(bundleId: String) -> Int64? {
        guard let stmt = try? prepare("SELECT id FROM apps WHERE bundle_id = ?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, bundleId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return nil
    }

    /// 按天 × 分类的时长分布（周/月视图图表数据）。
    /// 注意：SQLite 的 strftime('%s', …, 'start of day') 把本地午夜转回 epoch 时会丢时区偏移，
    /// 因此这里按「本地日期字符串」分组，再在 Swift 侧转回本地零点 epoch。
    func dailyBreakdown(from: Int, to: Int) -> [DayCategoryUsage] {
        var result: [DayCategoryUsage] = []
        guard let stmt = try? prepare("""
            SELECT strftime('%Y-%m-%d', s.start_ts, 'unixepoch', 'localtime') AS day,
                   \(effectiveCategorySQL), SUM(s.duration_ms)
            FROM sessions s JOIN apps a ON a.id = s.app_id
            \(domainJoinSQL)
            WHERE s.start_ts >= ? AND s.start_ts < ? AND \(webCountableSQL)
            GROUP BY day, \(effectiveCategorySQL)
            ORDER BY day
            """) else { return result }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, from)
        bind(stmt, 2, to)
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(DayCategoryUsage(
                dayStart: Self.dayStartEpoch(fromDayKey: columnText(stmt, 0)),
                category: AppCategory(dbValue: columnText(stmt, 1)),
                ms: Int(sqlite3_column_int64(stmt, 2))
            ))
        }
        return result
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    static func dayStartEpoch(fromDayKey key: String) -> Int {
        guard let date = dayKeyFormatter.date(from: key) else { return 0 }
        return Int(date.timeIntervalSince1970)
    }

    func sessions(appId: Int64, from: Int, to: Int) -> [SessionRow] {
        var result: [SessionRow] = []
        guard let stmt = try? prepare("""
            SELECT start_ts, end_ts, duration_ms FROM sessions
            WHERE app_id = ? AND start_ts >= ? AND start_ts < ?
            ORDER BY start_ts
            """) else { return result }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, appId)
        bind(stmt, 2, from)
        bind(stmt, 3, to)
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(SessionRow(
                startTs: Int(sqlite3_column_int64(stmt, 0)),
                endTs: Int(sqlite3_column_int64(stmt, 1)),
                durationMs: Int(sqlite3_column_int64(stmt, 2))
            ))
        }
        return result
    }
}
