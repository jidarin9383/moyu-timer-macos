import SwiftUI

struct MonthHeatmap: View {
    let snapshot: StatsViewModel.RangeSnapshot
    let live: StatsViewModel.LiveInfo?
    var now: Date
    @State private var hoveredDate: Date?

    init(snapshot: StatsViewModel.RangeSnapshot, live: StatsViewModel.LiveInfo?, hoveredDate: Date? = nil, now: Date = Date()) {
        self.snapshot = snapshot; self.live = live; self.now = now
        _hoveredDate = State(initialValue: hoveredDate)
    }
    private var data: MonthlyUsage {
        MonthlyUsage(from: snapshot.rangeStart, to: snapshot.rangeEnd, daily: snapshot.daily, live: live, now: now)
    }
    private var dates: [Date] {
        guard snapshot.rangeStart > 0, snapshot.rangeStart < snapshot.rangeEnd else { return [] }
        var result: [Date] = [], cursor = snapshot.rangeStart
        while cursor < snapshot.rangeEnd {
            result.append(Date(timeIntervalSince1970: Double(cursor)))
            let next = DayRange.nextLocalMidnight(after: cursor)
            guard next > cursor else { break }
            cursor = next
        }
        return result
    }
    private func description(_ date: Date, _ day: MonthlyUsage.Day?) -> String {
        let label = date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day())
        guard let day else { return "\(label) · 尚未到来" }
        guard day.totalMs > 0 else { return "\(label) · 暂无记录" }
        return "\(label) · 摸鱼率 \(Int((day.slackRate * 100).rounded()))% · 工作 \(AquariumStyle.duration(day.workMs)) · 摸鱼 \(AquariumStyle.duration(day.slackMs))"
    }
    var body: some View {
        let usage = data, dates = dates
        let leading = dates.first.map { (DayRange.localCalendar.component(.weekday, from: $0) + 5) % 7 } ?? 0
        let rowCount = (leading + dates.count + 6) / 7
        let height: CGFloat = rowCount > 5 ? 33 : 40
        VStack(spacing: 6) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { title in
                        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(AquariumStyle.muted)
                            .frame(maxWidth: .infinity).frame(height: 18)
                    }
                }
                ForEach(0..<rowCount, id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { column in
                            let index = row * 7 + column - leading
                            if dates.indices.contains(index) {
                                cell(dates[index], day: usage.day(containing: dates[index]), height: height)
                            } else { Color.clear.frame(height: height).accessibilityHidden(true) }
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer()
                Text("少摸")
                ForEach(0..<4) { level in RoundedRectangle(cornerRadius: 2).fill(AquariumStyle.heat[level]).frame(width: 9, height: 8) }
                Text("多摸")
            }
            .font(.system(size: 8.5)).foregroundStyle(AquariumStyle.muted).frame(height: 14)
        }
        .overlay(alignment: .top) {
            if let hoveredDate {
                Text(description(hoveredDate, usage.day(containing: hoveredDate)))
                    .font(.system(size: 10)).foregroundStyle(AquariumStyle.ink).padding(8)
                    .frame(maxWidth: 230).fixedSize(horizontal: false, vertical: true)
                    .background(AquariumStyle.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(AquariumStyle.border))
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                    .padding(.top, 16).allowsHitTesting(false)
            }
        }
        .onChange(of: snapshot.rangeStart) { _ in hoveredDate = nil }
    }
    private func cell(_ date: Date, day: MonthlyUsage.Day?, height: CGFloat) -> some View {
        let recorded = (day?.totalMs ?? 0) > 0
        let future = day == nil
        let level = AquariumHeat.level(rate: day?.slackRate ?? 0)
        let today = DayRange.localCalendar.isDate(date, inSameDayAs: now)
        return Text("\(DayRange.localCalendar.component(.day, from: date))")
            .font(.system(size: 11, weight: recorded || today ? .medium : .regular)).monospacedDigit()
            .foregroundStyle(recorded ? AquariumStyle.heatText(level: level) : AquariumStyle.muted)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(recorded ? AquariumStyle.heat[level] : AquariumStyle.surface)
            .overlay {
                if !recorded && !future {
                    Canvas { context, size in
                        var stripes = Path()
                        for x in stride(from: -size.height, through: size.width, by: 6) {
                            stripes.move(to: CGPoint(x: x, y: 0)); stripes.addLine(to: CGPoint(x: x + size.height, y: size.height))
                        }
                        context.stroke(stripes, with: .color(AquariumStyle.muted.opacity(0.12)), lineWidth: 2)
                    }.allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(today ? AquariumStyle.work : future ? AquariumStyle.border : .clear,
                       style: StrokeStyle(lineWidth: today ? 1.5 : 0.7, dash: future ? [2, 2] : [])))
            .contentShape(Rectangle())
            .onHover { inside in if inside { hoveredDate = date } else if hoveredDate == date { hoveredDate = nil } }
            .help(description(date, day)).accessibilityLabel(description(date, day))
            .focusable(true)
    }
}
