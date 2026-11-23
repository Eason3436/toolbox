import Foundation
import SwiftData

/// 工具執行時能用的東西：資料庫、在對話裡放卡片、等使用者按確認
@MainActor
protocol ToolHost: AnyObject {
    /// 在目前這則模型回覆裡放一張卡片
    func addCard(_ card: ToolCard)
    /// 換掉同一個 id 的卡片（確認卡加入後顯示結果）
    func updateCard(_ card: ToolCard)
    /// 放一張確認卡，等使用者按「加入」或「取消」。回傳決定和使用者改過的卡片
    func confirm(_ card: ToolCard) async -> (ConfirmDecision, ToolCard)
    /// report_image_content：把辨識文字記到有圖片的那則訊息，之後不再送圖片。沒有圖片可以對時回傳 nil
    func recordRecognition(transcript: String, imageType: String?, uncertain: [String]) -> UUID?
}

struct ToolContext {
    let modelContext: ModelContext
    unowned let host: ToolHost
    var now = Date()
}

/// 工具執行失敗：回給模型 {"error": "…"}，讓它自己修正重試
struct ToolFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

extension JSONValue {
    static func error(_ message: String) -> JSONValue { ["error": .string(message)] }

    var isToolError: Bool { self["error"] != nil }
}

/// 參數讀取（模型送來的 args）
struct ToolArgs {
    let raw: JSONValue

    init(_ raw: JSONValue) {
        self.raw = raw
    }

    func string(_ key: String) -> String? {
        guard let text = raw[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    func int(_ key: String, default value: Int, range: ClosedRange<Int>) -> Int {
        guard let number = raw[key]?.int else { return value }
        return min(max(number, range.lowerBound), range.upperBound)
    }

    func optionalInt(_ key: String) -> Int? { raw[key]?.int }

    func bool(_ key: String) -> Bool { raw[key]?.bool ?? false }

    func strings(_ key: String) -> [String] {
        raw[key]?.strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
    }

    func array(_ key: String) -> [JSONValue] { raw[key]?.array ?? [] }
}

/// 記得的機率、記憶點（supabase/DEPLOY-3.md 3.1）
enum Memory {
    private static let scheduler = FSRSScheduler()

    /// 新卡沒有
    static func recall(state: FSRSState, stability: Double, lastReview: Date?, now: Date) -> Double? {
        guard state != .new, let lastReview else { return nil }
        let days = max(now.timeIntervalSince(lastReview) / 86_400, 0)
        return scheduler.retrievability(elapsedDays: days, stability: stability)
    }

    /// ●●○○○：ceil(R × 5)，至少 1 顆；新卡是「新字」
    static func dots(_ recall: Double?) -> String {
        guard let recall else { return "新字" }
        let filled = min(5, max(1, Int((recall * 5).rounded(.up))))
        return String(repeating: "●", count: filled) + String(repeating: "○", count: 5 - filled)
    }

    static func round(_ value: Double, _ places: Int = 2) -> Double {
        let factor = pow(10, Double(places))
        return (value * factor).rounded() / factor
    }
}

extension Date {
    /// 2026-11-16（本地時區）
    var dayString: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
