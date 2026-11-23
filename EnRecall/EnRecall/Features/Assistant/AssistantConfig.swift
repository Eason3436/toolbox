import Foundation

/// 助理的模型與限制。要換模型改這裡就好（gemini-proxy 的白名單也要一起改，DEPLOY-8.md）
enum AssistantConfig {
    /// 一般模式
    static let defaultModel = "gemini-4-hydrogen"
    /// 精準模式：使用者按「精準重新辨識」或右上角切換時才用
    static let preciseModel = "gemini-4-neon"

    /// 思考程度（generationConfig.thinkingConfig.thinkingLevel）
    static let thinkingLevel = "LOW"
    /// 有新圖片的那一輪
    static let thinkingLevelWithImage = "MEDIUM"
    /// 有圖片時的解析度（generationConfig.mediaResolution）
    static let imageResolution = "MEDIA_RESOLUTION_HIGH"

    /// 一次請求最多幾輪工具呼叫
    static let maxToolRounds = 8
    /// 同一個工具錯誤最多讓模型重試幾次
    static let maxSameErrorRetries = 2
    /// 離開 App 超過這麼久，回來就是新的對話
    static let resetAfter: TimeInterval = 30 * 60

    /// 上傳前壓縮：長邊、JPEG 品質
    static let imageMaxEdge: CGFloat = 2048
    static let imageQuality: CGFloat = 0.8
    /// 一則訊息最多幾張圖
    static let maxImages = 4

    static let requestTimeout: TimeInterval = 120
}

enum AssistantMode: String, CaseIterable, Identifiable {
    case normal
    case precise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "一般"
        case .precise: "精準"
        }
    }

    var model: String {
        switch self {
        case .normal: AssistantConfig.defaultModel
        case .precise: AssistantConfig.preciseModel
        }
    }
}
