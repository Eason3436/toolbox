import Foundation

/// 首次啟動時選擇要匯入多久以前的截圖。
enum ImportRange: String, CaseIterable, Identifiable, Sendable {
    case last30
    case last90
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last30: "最近 30 天"
        case .last90: "最近 90 天"
        case .all: "全部"
        }
    }

    /// 起始日期；`nil` 代表不限。
    func startDate(now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .last30: calendar.date(byAdding: .day, value: -30, to: now)
        case .last90: calendar.date(byAdding: .day, value: -90, to: now)
        case .all: nil
        }
    }
}
