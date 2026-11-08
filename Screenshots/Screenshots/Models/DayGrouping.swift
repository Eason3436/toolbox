import Foundation

/// 首頁依日期分段用。
struct DaySection<Item: Identifiable>: Identifiable {
    let day: Date
    var items: [Item]
    var id: Date { day }
}

enum DayGrouping {
    /// 依「當天 00:00」把項目分段，輸入須已依時間新到舊排序。
    static func sections<Item: Identifiable>(
        from items: [Item],
        date: (Item) -> Date,
        calendar: Calendar = .current
    ) -> [DaySection<Item>] {
        var result: [DaySection<Item>] = []
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if result.last?.day == day {
                result[result.count - 1].items.append(item)
            } else {
                result.append(DaySection(day: day, items: [item]))
            }
        }
        return result
    }

    /// 段落標題：今天、昨天、11月1日 星期六；不同年份加上年份。
    static func title(for day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "昨天" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        let style = Date.FormatStyle(locale: Locale(identifier: "zh_Hant_TW"), calendar: calendar, timeZone: calendar.timeZone)
        return sameYear
            ? day.formatted(style.month(.defaultDigits).day().weekday(.wide))
            : day.formatted(style.year().month(.defaultDigits).day().weekday(.wide))
    }
}

/// 篩選用的日期範圍。
enum DateFilter: String, CaseIterable, Identifiable, Sendable {
    case any, today, week, month, year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "全部時間"
        case .today: "今天"
        case .week: "最近 7 天"
        case .month: "最近 30 天"
        case .year: "今年"
        }
    }

    func contains(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .any: return true
        case .today: return calendar.isDate(date, inSameDayAs: now)
        case .week: return date >= (calendar.date(byAdding: .day, value: -7, to: now) ?? now)
        case .month: return date >= (calendar.date(byAdding: .day, value: -30, to: now) ?? now)
        case .year: return calendar.component(.year, from: date) == calendar.component(.year, from: now)
        }
    }
}
