import FoundationModels
import UIKit

/// Foundation Models 產生的結構化分析結果。
@Generable
struct ScreenshotAnalysis {
    @Guide(description: "10 字以內的繁體中文標題")
    var title: String
    @Guide(description: "1～2 句繁體中文摘要")
    var summary: String
    @Guide(description: "最符合這張截圖內容的分類")
    var category: AnalysisCategory
    @Guide(description: "圖中出現的日期時間（照原文）")
    var dates: [String]
    @Guide(description: "地點、店名、地址")
    var places: [String]
    @Guide(description: "圖中出現的網址")
    var urls: [String]
    @Guide(description: "圖中出現的電話號碼")
    var phoneNumbers: [String]
    @Guide(description: "圖中出現的價格，含幣別")
    var prices: [String]
    @Guide(description: "3～8 個繁體中文或英文搜尋關鍵字")
    var keywords: [String]
}

/// 模型可選的分類（與 `ScreenshotCategory` 同名）。
@Generable
enum AnalysisCategory {
    case 購物, 美食, 旅遊, 學習筆記, 對話紀錄, 票券訂單, 程式碼, 財經, 社群貼文, 其他
}

extension AnalysisCategory {
    var appCategory: ScreenshotCategory {
        switch self {
        case .購物: .購物
        case .美食: .美食
        case .旅遊: .旅遊
        case .學習筆記: .學習筆記
        case .對話紀錄: .對話紀錄
        case .票券訂單: .票券訂單
        case .程式碼: .程式碼
        case .財經: .財經
        case .社群貼文: .社群貼文
        case .其他: .其他
        }
    }
}

/// 模型目前的狀態（給介面顯示）。
enum ModelReadiness: Equatable, Sendable {
    case available
    case appleIntelligenceOff
    case notReady
    case unsupported
    case unknown(String)

    static var current: ModelReadiness {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .notReady
        case .unavailable(.deviceNotEligible): return .unsupported
        case .unavailable(let other): return .unknown(String(describing: other))
        }
    }

    var message: String {
        switch self {
        case .available: "Apple Intelligence 已就緒"
        case .appleIntelligenceOff: "Apple Intelligence 尚未開啟。請到「設定 → Apple Intelligence 與 Siri」開啟，截圖會先排入待分析佇列。"
        case .notReady: "Apple Intelligence 模型還在下載或準備中，完成後會自動開始分析。"
        case .unsupported: "這台裝置不支援 Apple Intelligence。"
        case .unknown(let reason): "Apple Intelligence 目前無法使用（\(reason)）。"
        }
    }
}

/// 用裝置端模型分析截圖（圖片＋OCR 文字）。完全離線。
enum AIAnalyzer {
    static let instructions = """
    你是 iPhone 截圖整理助理。根據使用者提供的截圖與辨識出的文字，產生結構化資訊。
    一律使用台灣繁體中文。只寫圖中真的有的資訊，沒有就留空陣列，不要編造。
    """

    /// - Parameters:
    ///   - image: 已縮小的截圖
    ///   - ocrText: Vision 辨識出的文字；傳空字串代表不附文字（例如上下文太長重試時）
    static func analyze(image: UIImage, ocrText: String) async throws -> ScreenshotAnalysis {
        guard let cgImage = image.cgImage else { throw PhotoLoadError.imageUnavailable }
        let session = LanguageModelSession(instructions: instructions)
        let trimmed = String(ocrText.prefix(900))
        var text = "分析這張 iPhone 截圖，產生標題、摘要、分類與重點資訊。"
        if !trimmed.isEmpty {
            text += "\n截圖中辨識出的文字（可能有錯字或不完整）：\n\(trimmed)"
        }
        let prompt = text
        let response = try await session.respond(generating: ScreenshotAnalysis.self) {
            prompt
            Attachment(cgImage)
        }
        return response.content
    }
}
