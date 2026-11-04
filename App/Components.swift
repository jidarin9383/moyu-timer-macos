import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 格式化

enum Formatters {
    static func duration(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ ts: Int) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    static func dateRangeTitle(start: Int, end: Int) -> String {
        let s = Date(timeIntervalSince1970: TimeInterval(start))
        let e = Date(timeIntervalSince1970: TimeInterval(end - 1))
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = DayRange.localCalendar
        let calendar = DayRange.localCalendar
        let sameYearAsToday = calendar.isDate(s, equalTo: Date(), toGranularity: .year)
            && calendar.isDate(e, equalTo: Date(), toGranularity: .year)
        f.dateFormat = sameYearAsToday ? "M月d日" : "yyyy年M月d日"
        if calendar.isDate(s, inSameDayAs: e) { return f.string(from: s) }
        return "\(f.string(from: s)) – \(f.string(from: e))"
    }
}

// MARK: - App 图标（带缓存）

enum AppIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(bundleId: String) -> NSImage {
        if let cached = cache[bundleId] { return cached }
        var image = NSWorkspace.shared.icon(for: UTType.application)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        // copy 一份再改尺寸，避免直接改动 NSWorkspace 内部缓存的对象
        let sized = (image.copy() as? NSImage) ?? image
        sized.size = NSSize(width: 18, height: 18)
        sized.isTemplate = false   // 明确按原色渲染，避免被当模板图染灰
        cache[bundleId] = sized
        return sized
    }
}

// MARK: - 复用组件

/// The hover button and right-click menu use the same category actions.
private struct CategoryMenuItems: View {
    let current: AppCategory
    let onSelect: (AppCategory) -> Void

    var body: some View {
        ForEach(AppCategory.allCases) { option in
            if option != current {
                Button { onSelect(option) } label: {
                    Label(option == .ignored ? "忽略（不计入）" : "移到\(option.title)",
                          systemImage: option.menuSymbol)
                }
            }
        }
    }
}

/// 摘要里的一行：分类圆点 + 名称 + 时长。
/// 已忽略行整体降饱和（调用方传 .ignored 时用次要文字色）。
struct CategoryLine: View {
    let category: AppCategory
    let ms: Int

    private var dimmed: Bool { category == .ignored }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(category.color).frame(width: 8, height: 8)
            Text(category.title)
                .foregroundStyle(dimmed ? Palette.ink3 : Palette.ink)
            Spacer(minLength: 12)
            Text(Formatters.duration(ms))
                .monospacedDigit()
                .foregroundStyle(dimmed ? Palette.ink3 : category.deepColor)
        }
        .font(.system(size: 12))
    }
}

/// 100% 堆叠占比条。只含工作/摸鱼——「已忽略」不计入，不占条。
struct ProportionBar: View {
    let totals: [AppCategory: Int]

    private var total: Int { (totals[.work] ?? 0) + (totals[.slack] ?? 0) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach([AppCategory.work, .slack], id: \.self) { cat in
                    let ms = totals[cat] ?? 0
                    if ms > 0, total > 0 {
                        cat.color.frame(width: geo.size.width * Double(ms) / Double(total))
                    }
                }
            }
        }
        .frame(height: 6)
        .background(Palette.track)
        .clipShape(Capsule())
    }
}

/// 摸鱼率环形图（v1.0 设计稿：双弧拼满一圈）。
/// Teal = work, orange = leisure, starting clockwise from twelve o’clock.
/// 已忽略不占环。中心大数字只回答摸鱼率。
struct RateRing: View {
    let rate: Double
    /// 工作占总记录的比例（0...1）。total=0 时环是全灰底。
    let workRatio: Double

    init(rate: Double, totals: [AppCategory: Int]) {
        self.rate = rate
        let w = totals[.work] ?? 0, s = totals[.slack] ?? 0
        self.workRatio = (w + s) > 0 ? Double(w) / Double(w + s) : 0
    }

    private var hasData: Bool { workRatio > 0 || rate > 0 }

    var body: some View {
        ZStack {
            // 底环：无记录时全灰；有记录时只留极淡的轨道色打底
            Circle()
                .stroke(Palette.track, lineWidth: 8)
            if hasData {
                if workRatio > 0 {
                    Circle()
                        .trim(from: 0, to: min(1, workRatio))
                        .stroke(Palette.work,
                                style: StrokeStyle(lineWidth: 8, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                // Leisure continues after the work segment.
                if rate > 0 {
                    Circle()
                        .trim(from: max(0, min(1, workRatio)), to: 1)
                        .stroke(Palette.slack,
                                style: StrokeStyle(lineWidth: 8, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
            VStack(spacing: 1) {
                Text(hasData ? "\(Int((rate * 100).rounded()))%" : "—")
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
                Text(hasData ? "摸鱼率" : "暂无统计")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Palette.ink3)
            }
        }
        .frame(width: 76, height: 76)
    }
}

/// App 使用明细行：展开箭头、图标、名称、占比小条、时长、分类徽标。
/// v0.8 起点击行 = 行内展开/收起（不再有二级页面）。
/// 「网页统计」是虚拟行：用地球图标，代表全部浏览器归组。
/// v0.9：liveMs = 打开中会话的实时增量（由调用方算好传入，快照数组本身不每秒变）。
struct AppRow: View {
    let app: AppUsageRow
    let categoryTotalMs: Int
    let expanded: Bool
    let liveMs: Int
    var onChangeCategory: ((AppCategory) -> Void)? = nil
    var onToggle: (() -> Void)? = nil
    @State private var isHovered = false

    private var isWebGroup: Bool { app.bundleId == WebGroup.bundleId }
    private var identity: some View {
        HStack(spacing: 8) {
            if isWebGroup {
                Image(systemName: "globe").font(.system(size: 13))
                    .foregroundStyle(AquariumStyle.category(app.category))
                    .frame(width: 22, height: 22)
                    .background(AquariumStyle.leisure.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            } else {
                Image(nsImage: AppIcon.image(bundleId: app.bundleId)).resizable().frame(width: 20, height: 20)
                    .frame(width: 22, height: 22)
            }
            Text(app.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            if isWebGroup {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(AquariumStyle.muted)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(AquariumStyle.ink).contentShape(Rectangle())
    }
    var body: some View {
        HStack(spacing: 4) {
            if let onToggle {
                Button(action: onToggle) { identity }.buttonStyle(.plain)
                    .accessibilityLabel("网页统计").accessibilityValue(expanded ? "已展开" : "已收起")
            } else { identity }
            if let onChangeCategory {
                Menu { CategoryMenuItems(current: app.category, onSelect: onChangeCategory) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 20)
                .foregroundStyle(AquariumStyle.muted).opacity(isHovered ? 1 : 0.55)
                .help("修改\(app.name)分类").accessibilityLabel("修改\(app.name)分类")
            }
            Text(AquariumStyle.duration(app.ms + liveMs))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(AquariumStyle.ink).lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 18).frame(height: 30).contentShape(Rectangle())
        .background(isHovered ? AquariumStyle.surface : .clear)
        .onHover { isHovered = $0 }
    }
}

/// 「工作 / 摸鱼 / 已忽略」分块：块标题 + 该分类总时长 + 分类下的 App 列表。
/// v0.8：行内展开/收起代替二级页面——
/// - 「网页统计」行展开显示**该分类下**的网址停留时长（与行时长对账）；
/// - Ordinary apps show totals and keep their category context menu.
/// 右键普通 App 行可一键改分类；「网页统计」行没有 App 级右键菜单
/// （它的分类在展开区里按网址逐条调）。
struct CategoryAppBlock: View {
    let title: String
    let category: AppCategory
    let apps: [AppUsageRow]
    let total: Int
    let store: Store
    let from: Int
    let to: Int
    let liveMs: Int              // 该分类的实时增量（叠加到块总时长）
    let liveAppId: Int64?        // 哪一行是打开中会话（该行叠加 liveMs）

    /// Expansion is keyed by app and category across snapshot refreshes.
    @State private var expandedKey: String?

    var body: some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(AquariumStyle.category(category)).frame(width: 5, height: 5)
                    Text(title).foregroundStyle(AquariumStyle.muted)
                    Spacer()
                    Text(AquariumStyle.duration(total + liveMs)).fontWeight(.semibold).monospacedDigit()
                }
                .font(.system(size: 10.5)).foregroundStyle(AquariumStyle.ink)
                .padding(.horizontal, 18).frame(height: 18)
                VStack(spacing: 0) {
                    ForEach(apps) { app in row(for: app) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for app: AppUsageRow) -> some View {
        if app.bundleId == WebGroup.bundleId {
            webRow(for: app)
        } else {
            appRow(for: app)
        }
    }

    /// 「网页统计」行：点击展开该分类下的网址明细。
    @ViewBuilder
    private func webRow(for app: AppUsageRow) -> some View {
        let key = "\(app.appId)-\(category.rawValue)"
        let expanded = expandedKey == key
        VStack(spacing: 0) {
            AppRow(app: app, categoryTotalMs: total + liveMs, expanded: expanded,
                   liveMs: rowLiveMs(app.appId), onChangeCategory: { option in
                       let domains = store.domainUsage(appId: app.appId, from: from, to: to)
                           .filter { $0.category == category }
                       for domain in domains { store.setDomainCategory(domain: domain.domain, category: option) }
                   }, onToggle: { toggle(key) })
            if expanded {
                WebDomainList(store: store, app: app, category: category, from: from, to: to)
            }
        }
    }

    /// Ordinary apps keep their category context menu; session expansion is paused.
    private func appRow(for app: AppUsageRow) -> some View {
        AppRow(app: app, categoryTotalMs: total + liveMs, expanded: false,
               liveMs: rowLiveMs(app.appId),
               onChangeCategory: { store.setCategory(appId: app.appId, category: $0) })
            .contextMenu { categoryMenu(for: app) }
        // Session expansion is intentionally disabled at the user's request.
        // Button { toggle(key) } label: { AppRow(...) }
        // if expanded {
        //     AppSessionList(store: store, app: app, from: from, to: to)
        // }
    }

    /// 该行的实时增量：只有「打开中会话所属的那一行」拿得到。
    private func rowLiveMs(_ appId: Int64) -> Int {
        (liveAppId == appId) ? liveMs : 0
    }

    private func toggle(_ key: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedKey = (expandedKey == key) ? nil : key
        }
    }

    @ViewBuilder
    private func categoryMenu(for app: AppUsageRow) -> some View {
        CategoryMenuItems(current: app.category) {
            store.setCategory(appId: app.appId, category: $0)
        }
    }
}

/// 「网页统计」行展开内容（v0.8）：当前块分类下的网址停留时长。
/// 只统计成功读到网址的时段；右键某网址可把它移到其他分类（历史即时重算）。
/// 读不到网址的时段不计入，在这里以「未能读取网址」透明提示，不混进列表。
struct WebDomainList: View {
    let store: Store
    let app: AppUsageRow
    let category: AppCategory       // 当前块（工作/摸鱼）：只展示该分类下的域名
    let from: Int
    let to: Int

    /// 右键改分类后立即重算（父视图每秒重渲也会自然刷新）
    @State private var revision = 0
    @State private var hoveredDomain: String?

    private var domains: [DomainUsageRow] {
        _ = revision
        return store.domainUsage(appId: app.appId, from: from, to: to)
            .filter { $0.category == category }
    }

    private var uncountedMs: Int {
        _ = revision
        return store.uncountedWebMs(appId: app.appId, from: from, to: to)
    }

    var body: some View {
        let rows = domains
        let missingMs = uncountedMs
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("该分类下暂无网址记录")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 42)
                    .padding(.trailing, 18)
                    .padding(.vertical, 6)
            } else {
                ForEach(rows) { d in
                    domainRow(d)
                }
            }
            if missingMs > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                    Text("未能读取网址 \(Formatters.duration(missingMs))，未计入时长")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 42)
                    .padding(.trailing, 18)
                .padding(.vertical, 6)
            }
        }
        .padding(.bottom, 4)
    }

    /// Domain and duration align with the parent row's name and duration columns.
    @ViewBuilder
    private func domainRow(_ d: DomainUsageRow) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(d.domain)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                CategoryMenuItems(current: d.category) { option in
                    store.setDomainCategory(domain: d.domain, category: option)
                    revision += 1
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AquariumStyle.muted)
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .opacity(hoveredDomain == d.domain ? 1 : 0.55)
            .help("修改\(d.domain)分类")
            .accessibilityLabel("修改\(d.domain)分类")
            Text(AquariumStyle.duration(d.ms))
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 70, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 42)
        .padding(.trailing, 18)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hoveredDomain = $0 ? d.domain : nil }
        row.contextMenu {
            CategoryMenuItems(current: d.category) { option in
                store.setDomainCategory(domain: d.domain, category: option)
                revision += 1
            }
        }
    }
}

// Temporarily disabled: per-session details for individual apps.
/*
/// 普通 App 行展开内容（v0.8）：分类切换（即时重算）+ 会话明细。
struct AppSessionList: View {
    let store: Store
    let app: AppUsageRow
    let from: Int
    let to: Int

    @State private var category: AppCategory

    init(store: Store, app: AppUsageRow, from: Int, to: Int) {
        self.store = store
        self.app = app
        self.from = from
        self.to = to
        _category = State(initialValue: app.category)
    }

    private var sessions: [SessionRow] { store.sessions(appId: app.appId, from: from, to: to) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("分类归属")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("分类", selection: $category) {
                    ForEach(AppCategory.allCases) { cat in
                        Text(cat.title).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: category) { newValue in
                    store.setCategory(appId: app.appId, category: newValue)
                }
                Text("修改后，所有历史统计会按新分类立即重新计算；「已忽略」不计入工作/摸鱼时长。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 34)
            .padding(.top, 4)

            if sessions.isEmpty {
                Text("暂无会话记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 34)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, s in
                        HStack {
                            Text("\(Formatters.time(s.startTs)) – \(Formatters.time(s.endTs))")
                                .font(.system(size: 11).monospacedDigit())
                            Spacer()
                            Text(Formatters.duration(s.durationMs))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 34)
                        .padding(.vertical, 3)
                        if index < sessions.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }
}

*/
