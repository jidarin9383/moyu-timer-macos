import SwiftUI

/// Compact calendar statistics. Hover/focus reveals details without navigation or layout shifts.
struct PeriodView: View {
    let period: StatsViewModel.Tab
    let snapshot: StatsViewModel.RangeSnapshot
    let store: Store
    let live: StatsViewModel.LiveInfo?
    var now: Date = Date()
    @State private var hoveredDay: MonthlyUsage.Day?

    init(period: StatsViewModel.Tab, snapshot: StatsViewModel.RangeSnapshot, store: Store,
         live: StatsViewModel.LiveInfo?, hoveredDay: MonthlyUsage.Day? = nil, now: Date = Date()) {
        self.period = period; self.snapshot = snapshot; self.store = store; self.live = live; self.now = now
        _hoveredDay = State(initialValue: hoveredDay)
    }
    private var usage: MonthlyUsage {
        MonthlyUsage(from: snapshot.rangeStart, to: snapshot.rangeEnd, daily: snapshot.daily, live: live, now: now)
    }
    private var summary: AquariumSummary {
        AquariumSummary(workMs: usage.days.reduce(0) { $0 + $1.workMs }, slackMs: usage.days.reduce(0) { $0 + $1.slackMs })
    }
    private var weekDates: [Date] {
        (0..<7).compactMap { DayRange.localCalendar.date(byAdding: .day, value: $0,
                             to: Date(timeIntervalSince1970: Double(snapshot.rangeStart))) }
    }
    private var scale: AquariumWeekScale { AquariumWeekScale(maxMinutes: Double(usage.days.map(\.totalMs).max() ?? 0) / 60_000) }

    var body: some View {
        VStack(spacing: 0) {
            if period == .week {
                weekChart.padding(.top, 8)
                HStack(spacing: 16) {
                    legend("工作时长", color: AquariumStyle.work)
                    legend("摸鱼时长", color: AquariumStyle.leisure)
                }.padding(.top, 10).padding(.bottom, 14)
                summaryBox
            } else {
                HStack { Spacer(); Text("橙色深浅 = 摸鱼率").font(.system(size: 9)).foregroundStyle(AquariumStyle.muted) }
                    .padding(.horizontal, 16).padding(.bottom, 6)
                MonthHeatmap(snapshot: snapshot, live: live, now: now).padding(.horizontal, 14)
                summaryBox.padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(AquariumStyle.ink)
        .onChange(of: snapshot.rangeStart) { _ in hoveredDay = nil }
    }

    private var weekChart: some View {
        GeometryReader { geometry in
            let plotHeight: CGFloat = 146
            let left: CGFloat = 22
            let columnWidth = (geometry.size.width - left) / 7
            ZStack(alignment: .topLeading) {
                ForEach(0..<3) { index in
                    let y = CGFloat(index) * plotHeight / 2
                    Text("\(Int(scale.maximumHours * Double(2 - index) / 2))h")
                        .font(.system(size: 8.5, design: .monospaced)).foregroundStyle(AquariumStyle.muted)
                        .frame(width: 20, alignment: .leading).offset(y: y - 5)
                    Path { path in path.move(to: CGPoint(x: left, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y)) }
                        .stroke(AquariumStyle.border, style: StrokeStyle(lineWidth: 0.6, dash: index == 2 ? [] : [2, 3]))
                }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(weekDates.enumerated()), id: \.element) { index, date in
                        let day = usage.day(containing: date)
                        let future = DayRange.day(date).start > DayRange.day(now).start
                        let work = Double(day?.workMs ?? 0) / 3_600_000 / scale.maximumHours * plotHeight
                        let slack = Double(day?.slackMs ?? 0) / 3_600_000 / scale.maximumHours * plotHeight
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottom) {
                                Color.clear
                                if future {
                                    RoundedRectangle(cornerRadius: 3).fill(AquariumStyle.surface)
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(AquariumStyle.border, style: StrokeStyle(lineWidth: 1, dash: [2])))
                                        .overlay(Text("未\n到").font(.system(size: 8)).foregroundStyle(AquariumStyle.muted))
                                        .frame(width: 18, height: 38)
                                } else if work + slack > 0 {
                                    VStack(spacing: 0) {
                                        if slack > 0 { AquariumStyle.leisure.frame(height: slack) }
                                        if work > 0 { AquariumStyle.work.frame(height: work) }
                                    }
                                    .frame(width: 21).clipShape(RoundedRectangle(cornerRadius: 3))
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(DayRange.localCalendar.isDate(date, inSameDayAs: now) ? AquariumStyle.workText : .clear, lineWidth: 1))
                                } else {
                                    Capsule().fill(AquariumStyle.border).frame(width: 18, height: 2)
                                }
                            }
                            .frame(height: plotHeight).frame(maxWidth: .infinity)
                            Text(["一", "二", "三", "四", "五", "六", "日"][index])
                                .font(.system(size: 10, weight: DayRange.localCalendar.isDate(date, inSameDayAs: now) ? .semibold : .regular))
                                .foregroundStyle(DayRange.localCalendar.isDate(date, inSameDayAs: now) ? AquariumStyle.workText : AquariumStyle.muted)
                        }
                        .frame(width: columnWidth).contentShape(Rectangle())
                        .onHover { inside in hoveredDay = inside && !future ? day : nil }
                        .help(weekDescription(date, day: day, future: future))
                        .accessibilityElement(children: .ignore).accessibilityLabel(weekDescription(date, day: day, future: future))
                    }
                }.offset(x: left)
                if let hoveredDay {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hoveredDay.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day())).bold()
                        Text("工作 \(AquariumStyle.duration(hoveredDay.workMs))")
                        Text("摸鱼 \(AquariumStyle.duration(hoveredDay.slackMs))")
                    }
                    .font(.system(size: 10)).padding(8).frame(width: 126, alignment: .leading)
                    .background(AquariumStyle.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(AquariumStyle.border))
                    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
                    .offset(x: min(max(0, left + CGFloat(weekDates.firstIndex(of: hoveredDay.date) ?? 0) * columnWidth - 45), geometry.size.width - 126), y: 8)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 168).padding(.horizontal, 18)
    }

    private func weekDescription(_ date: Date, day: MonthlyUsage.Day?, future: Bool) -> String {
        let title = date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday())
        if future { return "\(title) · 尚未到来" }
        guard let day, day.totalMs > 0 else { return "\(title) · 暂无记录" }
        return "\(title) · 工作 \(AquariumStyle.duration(day.workMs)) · 摸鱼 \(AquariumStyle.duration(day.slackMs))"
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 5, height: 5); Text(title) }
            .font(.system(size: 9.5)).foregroundStyle(AquariumStyle.muted)
    }
    private var summaryBox: some View {
        VStack(spacing: 6) {
            HStack {
                summaryMetric(period == .week ? "工作总计" : "工作总时长", ms: summary.workMs, color: AquariumStyle.ink)
                Spacer(minLength: 4)
                summaryMetric(period == .week ? "摸鱼总计" : "摸鱼总时长", ms: summary.slackMs, color: AquariumStyle.leisureText)
            }
            HStack {
                Text(period == .week ? "追踪总计: \(AquariumStyle.duration(summary.totalMs))" : "有效记录: \(usage.recordedDays) 天")
                Spacer(minLength: 0)
                if period == .month {
                    Text("摸鱼率: \(summary.rate.map { "\($0)%" } ?? "—")")
                        .foregroundStyle(AquariumStyle.leisureText)
                } else {
                    Text(weekDates.last.map { $0 > now } == true ? "未到日期不计入" : "7天周期")
                }
            }.font(.system(size: 9.5)).foregroundStyle(AquariumStyle.muted).monospacedDigit()
        }
        .padding(10).background(AquariumStyle.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(AquariumStyle.border, lineWidth: 0.6))
        .padding(.horizontal, 14)
    }
    private func summaryMetric(_ label: String, ms: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label + ":").font(.system(size: 10))
            Text(AquariumStyle.duration(ms)).font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(color)
        }.lineLimit(1).minimumScaleFactor(0.85)
    }
}
