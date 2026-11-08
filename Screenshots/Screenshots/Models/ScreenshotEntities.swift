import Foundation

/// 截圖中偵測到的資訊。
struct ScreenshotEntities: Codable, Sendable, Equatable {
    var dates: [DetectedDate] = []
    var places: [String] = []
    var urls: [String] = []
    var phoneNumbers: [String] = []
    var prices: [String] = []

    var isEmpty: Bool {
        dates.isEmpty && places.isEmpty && urls.isEmpty && phoneNumbers.isEmpty && prices.isEmpty
    }
}

/// 日期原文，以及能解析時的實際時間（加入行事曆／提醒事項用）。
struct DetectedDate: Codable, Sendable, Equatable, Hashable {
    var text: String
    var date: Date?
    var duration: TimeInterval?
}

/// 分類。`@Generable` 版本在 AIAnalyzer 裡，這裡是 App 用的顯示資訊。
enum ScreenshotCategory: String, CaseIterable, Identifiable, Sendable {
    case 購物, 美食, 旅遊, 學習筆記, 對話紀錄, 票券訂單, 程式碼, 財經, 社群貼文, 其他

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .購物: "bag"
        case .美食: "fork.knife"
        case .旅遊: "airplane"
        case .學習筆記: "book"
        case .對話紀錄: "bubble.left.and.bubble.right"
        case .票券訂單: "ticket"
        case .程式碼: "chevron.left.forwardslash.chevron.right"
        case .財經: "chart.line.uptrend.xyaxis"
        case .社群貼文: "person.2"
        case .其他: "square.dashed"
        }
    }
}
