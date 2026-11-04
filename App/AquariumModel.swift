import Foundation

/// Counted statistics shared by the habitat, summaries and charts. Ignored time never enters this model.
struct AquariumSummary {
    let workMs: Int
    let slackMs: Int
    var totalMs: Int { workMs + slackMs }
    var rate: Int? { totalMs > 0 ? Int((Double(slackMs) / Double(totalMs) * 100).rounded()) : nil }
    var phrase: String {
        guard let rate else { return "等待开启 · 静待游动" }
        if rate <= 20 { return "水波微漾 · 专注如常" }
        if rate <= 35 { return "游一会儿，刚刚好" }
        if rate <= 50 { return "浮出水面 · 适度偷闲" }
        return "尽情游弋 · 放松充电"
    }
}

struct AquariumWeekScale {
    let maximumHours: Double
    init(maxMinutes: Double) {
        let hours = maxMinutes / 60
        if hours <= 0 { maximumHours = 6 }
        else if hours <= 3 { maximumHours = 4 }
        else if hours <= 6 { maximumHours = 6 }
        else if hours <= 8 { maximumHours = 8 }
        else { maximumHours = ceil(hours / 2) * 2 }
    }
}

enum AquariumHeat {
    static func level(rate: Double) -> Int {
        if rate <= 0.20 { return 0 }
        if rate <= 0.35 { return 1 }
        if rate <= 0.50 { return 2 }
        return 3
    }
}
