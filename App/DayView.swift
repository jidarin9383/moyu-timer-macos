import SwiftUI

struct DayView: View {
    let snapshot: StatsViewModel.DaySnapshot
    let store: Store
    let live: StatsViewModel.LiveInfo?
    var permission: String? = nil
    var onAuthorize: (String?) -> Void = { _ in }
    @State private var showsIgnored = false

    private func extra(_ category: AppCategory) -> Int { live?.category == category ? live?.ms ?? 0 : 0 }
    private var counted: Int {
        (snapshot.categoryTotals[.work] ?? 0) + (snapshot.categoryTotals[.slack] ?? 0) + extra(.work) + extra(.slack)
    }
    private var ignored: [AppUsageRow] { snapshot.apps.filter { $0.category == .ignored } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let permission {
                    HStack(spacing: 6) {
                        Image(systemName: "globe.badge.chevron.backward")
                        Text(permission).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { onAuthorize(nil) } label: {
                            Text("授权").font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(AquariumStyle.work.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                    }
                    .foregroundStyle(AquariumStyle.workText).padding(8)
                    .background(AquariumStyle.habitatTop, in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 14)
                }
                HStack {
                    Text("时间去向")
                    Spacer()
                    Text("总计 \(AquariumStyle.duration(counted))").monospacedDigit()
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(AquariumStyle.muted)
                .padding(.horizontal, 18).frame(height: 18)
                if snapshot.apps.isEmpty && live == nil {
                    VStack(spacing: 9) {
                        AquariumArtwork(name: "fish-empty").frame(width: 52, height: 40).opacity(0.75)
                        Text(snapshot.rangeStart == DayRange.day(Date()).start
                             ? "水面平静 · 今天还没有记录到活动" : "水面平静 · 这一天暂无活动记录")
                            .font(.system(size: 11)).foregroundStyle(AquariumStyle.muted)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 30)
                } else {
                    block(.work)
                    block(.slack)
                    if !ignored.isEmpty {
                        Button { showsIgnored.toggle() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: showsIgnored ? "chevron.down" : "chevron.right").font(.system(size: 8))
                                Text("已忽略 · \(ignored.count) 项").font(.system(size: 10.5))
                                Spacer()
                            }.foregroundStyle(AquariumStyle.muted).padding(.horizontal, 18).frame(height: 22)
                        }.buttonStyle(.plain).accessibilityLabel(showsIgnored ? "收起已忽略项目" : "展开已忽略项目")
                        if showsIgnored { block(.ignored) }
                    }
                }
            }.padding(.top, 2).padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func block(_ category: AppCategory) -> some View {
        CategoryAppBlock(title: category.title, category: category,
                         apps: snapshot.apps.filter { $0.category == category },
                         total: snapshot.categoryTotals[category] ?? 0, store: store,
                         from: snapshot.rangeStart, to: snapshot.rangeEnd,
                         liveMs: extra(category), liveAppId: live?.appId)
    }
}
