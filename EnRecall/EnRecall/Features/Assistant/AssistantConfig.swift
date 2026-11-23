import Foundation

/// 助理的模型與限制。要換模型改這裡（claude-proxy 的白名單也要一起改，supabase/DEPLOY-9.md）
enum AssistantConfig {
    static let model = "claude-opus-5-5"

    /// 思考深度（output_config.effort）。一般用 medium，精準模式（含「精準重新辨識」）用 high
    static let normalEffort = "medium"
    static let preciseEffort = "high"

    static let maxTokens = 16_000

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

    /// 代理那邊用串流等完整回覆，這裡要等久一點
    static let requestTimeout: TimeInterval = 180
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

    var effort: String {
        switch self {
        case .normal: AssistantConfig.normalEffort
        case .precise: AssistantConfig.preciseEffort
        }
    }
}
