import Foundation

struct DayCount: Identifiable, Equatable {
    let date: Date
    let count: Int
    var id: Date { date }
}

/// 紀錄頁、首頁的數字：從 ReviewLog 算
enum StatsCalculator {
    /// 每天的複習張數，最舊的在前，最後一天是今天
    static func dailyCounts(_ logs: [ReviewLog], days: Int, now: Date = Date(), calendar: Calendar = .current) -> [DayCount] {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var counts: [Date: Int] = [:]
        for log in logs where log.reviewedAt >= first {
            counts[calendar.startOfDay(for: log.reviewedAt), default: 0] += 1
        }
        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            return DayCount(date: date, count: counts[date] ?? 0)
        }
    }

    /// 連續天數：今天有複習就從今天算；今天還沒複習就從昨天算（不會因為還沒開始就歸零）
    static func streak(_ logs: [ReviewLog], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(logs.map { calendar.startOfDay(for: $0.reviewedAt) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    /// 熱力圖 5 階：0 張是第 0 階，其他依當期最多的那天等比分 4 階
    static func heatLevel(_ count: Int, max maxCount: Int) -> Int {
        guard count > 0, maxCount > 0 else { return 0 }
        let ratio = Double(count) / Double(maxCount)
        return min(4, max(1, Int((ratio * 4).rounded(.up))))
    }
}
