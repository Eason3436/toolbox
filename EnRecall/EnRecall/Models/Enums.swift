import Foundation

/// 牌組從哪裡來
enum DeckKind: String, Codable {
    /// 單字商店下載的包（id = 包 id，例如 gsat-1）
    case storePack
    /// 從 Claude 匯入建立的牌組（id = "custom:" + UUID）
    case custom
}

/// 記憶卡／片語卡（牌組頁上方的分段）
enum DeckCategory: String, Codable, CaseIterable, Identifiable {
    case word
    case phrase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .word: "記憶卡"
        case .phrase: "片語卡"
        }
    }
}

/// 牌組的出卡模式
enum DeckMode: String, Codable, CaseIterable, Identifiable {
    case paused
    case active
    case reviewOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paused: "暫停"
        case .active: "出新卡"
        case .reviewOnly: "只出複習"
        }
    }
}

/// 新卡出現順序
enum NewCardOrder: String, Codable, CaseIterable, Identifiable {
    case sequential
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sequential: "依序"
        case .random: "隨機抽"
        }
    }
}

enum CardSource: String, Codable {
    /// 單字庫（商店的單字包或片語總表）
    case library
    /// Claude 寫的（例句旁顯示「AI 例句」）
    case claude
}

/// FSRS 卡片狀態
enum FSRSState: Int, Codable {
    case new = 0
    case learning = 1
    case review = 2
    case relearning = 3
}

/// 評分：1 不會 / 2 模糊 / 3 認識 / 4 很熟
enum Rating: Int, Codable, CaseIterable, Identifiable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .again: "不會"
        case .hard: "模糊"
        case .good: "認識"
        case .easy: "很熟"
        }
    }
}
