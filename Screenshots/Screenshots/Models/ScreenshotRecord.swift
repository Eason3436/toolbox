import Foundation

/// 一張截圖的輕量資料（階段 1 直接來自 PhotoKit，階段 2 改存 SwiftData）。
struct ScreenshotRecord: Identifiable, Hashable, Sendable {
    /// `PHAsset.localIdentifier`
    let id: String
    /// 在目前 PHFetchResult 裡的位置，用來快速取回 PHAsset。
    let index: Int
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
}

/// 首頁依日期分段用。
struct DaySection: Identifiable, Sendable {
    let day: Date
    var items: [ScreenshotRecord]
    var id: Date { day }
}

enum DayGrouping {
    /// 依「當天 00:00」把截圖分段，輸入須已依時間新到舊排序。
    static func sections(from records: [ScreenshotRecord], calendar: Calendar = .current) -> [DaySection] {
        var result: [DaySection] = []
        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            if result.last?.day == day {
                result[result.count - 1].items.append(record)
            } else {
                result.append(DaySection(day: day, items: [record]))
            }
        }
        return result
    }

    /// 段落標題：今天、昨天、11月1日 星期六；不同年份加上年份。
    static func title(for day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        let style = Date.FormatStyle(locale: Locale(identifier: "zh_Hant_TW"), calendar: calendar)
        let formatted = sameYear
            ? day.formatted(style.month(.defaultDigits).day().weekday(.wide))
            : day.formatted(style.year().month(.defaultDigits).day().weekday(.wide))
        return formatted
    }
}
