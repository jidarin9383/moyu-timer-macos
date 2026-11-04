import SwiftUI

struct AquariumShell<Content: View>: View {
    let tab: StatsViewModel.Tab
    let paused: Bool
    let onTab: (StatsViewModel.Tab) -> Void
    let onSettings: () -> Void
    let onPause: () -> Void
    let onQuit: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                AquariumArtwork(name: "logo-mark").frame(width: 17, height: 17)
                Text("摸了个鱼").font(.system(size: 13, weight: .bold))
                Circle().fill(paused ? AquariumStyle.paused : AquariumStyle.running)
                    .frame(width: 5, height: 5)
                    .padding(2).background((paused ? AquariumStyle.paused : AquariumStyle.running).opacity(0.15), in: Circle())
                    .help(paused ? "已暂停 · 不记录使用时间" : "运行中 · 正在记录")
                    .accessibilityLabel(paused ? "计时已暂停" : "计时运行中")
                Spacer(minLength: 4)
                HStack(spacing: 1) {
                    ForEach(StatsViewModel.Tab.allCases) { item in
                        Button { onTab(item) } label: {
                            Text(item.rawValue).font(.system(size: 11, weight: tab == item ? .semibold : .medium))
                                .foregroundStyle(tab == item ? AquariumStyle.ink : AquariumStyle.muted)
                                .frame(width: 27, height: 22)
                                .background(tab == item ? AquariumStyle.background : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain).accessibilityLabel("\(item.rawValue)视图")
                        .accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                }
                .padding(2).background(AquariumStyle.subtle, in: RoundedRectangle(cornerRadius: 7))
                Button(action: onSettings) {
                    Image(systemName: "gearshape").font(.system(size: 13)).frame(width: 22, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(AquariumStyle.muted).help("打开设置")
                .accessibilityLabel("打开设置")
            }
            .padding(.horizontal, 14).frame(height: 38)
            Rectangle().fill(AquariumStyle.border).frame(height: 0.5)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(AquariumStyle.border).frame(height: 0.5)
            HStack {
                Button(action: onPause) {
                    Label(paused ? "继续计时" : "暂停计时", systemImage: paused ? "play.fill" : "pause.fill")
                }
                Spacer()
                Button(action: onQuit) { Label("退出", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            .font(.system(size: 10.5, weight: .medium))
            .buttonStyle(.plain).foregroundStyle(AquariumStyle.muted)
            .padding(.horizontal, 16).frame(height: 30)
        }
        .foregroundStyle(AquariumStyle.ink)
        .frame(width: 348, height: 460)
        .background(AquariumStyle.background)
    }
}

struct AquariumNavigator: View {
    let title: String
    let tab: StatsViewModel.Tab
    let current: Bool
    let canGoNext: Bool
    let previous: () -> Void
    let next: () -> Void
    let back: () -> Void
    var trailing: String = ""

    private var unit: String { tab == .day ? "天" : tab == .week ? "周" : "个月" }
    var body: some View {
        HStack(spacing: 2) {
            Button(action: previous) { Image(systemName: "chevron.left").frame(width: 20, height: 22) }
                .accessibilityLabel("上一\(unit)")
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            Button(action: next) { Image(systemName: "chevron.right").frame(width: 20, height: 22) }
                .disabled(!canGoNext).opacity(canGoNext ? 1 : 0.3).accessibilityLabel("下一\(unit)")
            if !current {
                Button(action: back) { Text(tab == .day ? "今日" : tab == .week ? "本周" : "本月")
                    .font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(AquariumStyle.surface, in: RoundedRectangle(cornerRadius: 4)) }
                    .foregroundStyle(AquariumStyle.workText).accessibilityLabel("返回当前周期")
            }
            Spacer(minLength: 0)
            if !trailing.isEmpty {
                Text(trailing).font(.system(size: 10, weight: .medium)).foregroundStyle(AquariumStyle.workText)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(AquariumStyle.habitatBottom, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(.system(size: 9, weight: .semibold)).buttonStyle(.plain)
        .frame(height: 26).padding(.horizontal, 10)
    }
}

struct AquariumHabitat: View {
    let summary: AquariumSummary
    let paused: Bool
    var motionEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var brain = FishBrain()
    @State private var visible = true
    @State private var scrolling = false
    @State private var scrollRevision = 0
    private var motionAllowed: Bool { motionEnabled && !reduceMotion }
    /// 弹窗关闭或列表滚动时冻结在当前帧，恢复后从原处接着游
    private var running: Bool { motionAllowed && visible && !scrolling }

    var body: some View {
        ZStack(alignment: .leading) {
            TimelineView(.animation(minimumInterval: paused ? 1 / 15 : 1 / 30, paused: !running)) { context in
                let painter = AquariumScenePainter(dark: colorScheme == .dark)
                Canvas { graphics, size in
                    guard motionAllowed else {
                        painter.paintStill(graphics, size: size, asleep: paused, curious: summary.rate == nil)
                        return
                    }
                    brain.resize(to: size)
                    if running {
                        brain.advance(to: context.date.timeIntervalSinceReferenceDate,
                                      mood: FishMood(rate: summary.rate), asleep: paused)
                    }
                    painter.paint(graphics, size: size, brain: brain)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.rate.map { "\($0)%" } ?? "—")
                    .font(.system(size: 30, weight: .heavy)).monospacedDigit()
                Text("摸鱼率").font(.system(size: 10.5, weight: .semibold))
                HStack(spacing: 3) {
                    Image(systemName: paused ? "zzz" : "water.waves").font(.system(size: 8))
                    Text(paused ? "闲置打盹 · 计时已暂停" : summary.phrase).lineLimit(1)
                }
                .font(.system(size: 10)).padding(.top, 3)
            }
            .foregroundStyle(AquariumStyle.workText)
            .padding(.horizontal, 14)
            .allowsHitTesting(false)
        }
        .frame(height: 88)
        .contentShape(Rectangle())
        // 悬停时小鱼盯着指针并游过来；点鱼受惊冲开，点水面投喂鱼食
        .onContinuousHover { phase in
            if case .active(let location) = phase { brain.pointer = location } else { brain.pointer = nil }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            if running { brain.tap(at: value.location) }
        })
        .background(LinearGradient(colors: [AquariumStyle.habitatTop, AquariumStyle.habitatBottom], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(AquariumStyle.habitatBorder, lineWidth: 1))
        .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 6)
        .onAppear { visible = true }.onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in visible = true }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willCloseNotification)) { _ in visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { _ in scrolling = true }
        .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didLiveScrollNotification)) { _ in
            scrolling = true
            scrollRevision += 1
            let revision = scrollRevision
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if scrollRevision == revision { scrolling = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didEndLiveScrollNotification)) { _ in scrolling = false }
    }
}

struct AquariumDaySummary: View {
    let summary: AquariumSummary
    var body: some View {
        HStack(spacing: 0) {
            metric("工作", value: summary.workMs, color: AquariumStyle.work)
            Rectangle().fill(AquariumStyle.border).frame(width: 1, height: 16).padding(.horizontal, 12)
            metric("摸鱼", value: summary.slackMs, color: AquariumStyle.leisure)
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(AquariumStyle.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(AquariumStyle.border, lineWidth: 0.6))
        .padding(.horizontal, 14).padding(.bottom, 6)
    }
    private func metric(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).foregroundStyle(AquariumStyle.muted).font(.system(size: 10))
            Text(AquariumStyle.duration(value)).font(.system(size: 11, weight: .bold)).monospacedDigit()
            if title == "工作" { Spacer(minLength: 0) }
        }
    }
}
