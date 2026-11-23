import Foundation

/// 聊天頁的一則訊息
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case model
    }

    let id: UUID
    let role: Role
    var text: String?
    /// 只有這次新上傳、還沒辨識時有值（送出用，已壓縮的 JPEG）。辨識後清掉，之後只送文字
    var imageData: [Data]
    /// 縮圖只留在畫面上（不送出）
    var thumbnails: [Data]
    /// report_image_content 回報的辨識結果，取代圖片
    var recognizedText: String?
    /// 模型這則回覆的卡片（辨識結果、確認卡、PDF…）
    var cards: [ToolCard]
    /// 送出失敗：訊息下方顯示「重試」
    var error: String?
    var canRetry = false
    /// 這則是用精準模式送的
    var usedPreciseModel = false

    init(id: UUID = UUID(), role: Role, text: String? = nil, imageData: [Data] = [], thumbnails: [Data] = [],
         recognizedText: String? = nil, cards: [ToolCard] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.imageData = imageData
        self.thumbnails = thumbnails
        self.recognizedText = recognizedText
        self.cards = cards
    }

    var hasImages: Bool { !thumbnails.isEmpty }
}

/// 送給 Claude 的對話紀錄（跟畫面上的訊息分開）：
/// - 使用者那一則只記訊息 id，送出時再看要放圖片還是辨識後的文字
/// - 模型回傳的 content 原樣保存（含 thinking 區塊和 signature）
/// - 工具結果是 tool_result 區塊
enum HistoryItem: Equatable {
    case user(UUID)
    case model([JSONValue])
    case toolResults([JSONValue])
}

/// 工具結果卡片
struct ToolCard: Identifiable, Equatable {
    let id: UUID
    var kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    enum Kind: Equatable {
        case recognition(RecognitionCard)
        case words(WordProposal)
        case patterns(PatternProposal)
        case learning(LearningCard)
        case pdf(PDFCard)
    }
}

struct RecognitionCard: Equatable {
    /// 對應的使用者訊息
    var messageID: UUID
    var transcript: String
    var imageType: String?
    var uncertain: [String]
}

/// 確認卡的狀態
enum ProposalState: Equatable {
    case pending
    case added(String)
    case cancelled
}

struct WordProposal: Equatable {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        var word: String
        var pos: String?
        var zh: String
        var example: String?
        var exampleZh: String?
        var libraryWordID: String?
        var included = true

        var isLibrary: Bool { libraryWordID != nil }
    }

    var deck: String
    var items: [Item]
    var rejected: [(word: String, reason: String)]
    var state: ProposalState = .pending

    static func == (a: WordProposal, b: WordProposal) -> Bool {
        a.deck == b.deck && a.items == b.items && a.state == b.state
            && a.rejected.map(\.word) == b.rejected.map(\.word)
    }
}

struct PatternProposal: Equatable {
    struct Item: Identifiable, Equatable {
        var id: String
        var detail: PatternDetail
        /// 句型庫（App 裡）已經有
        var fromLibrary: Bool
        /// update_library：會用新內容覆蓋 App 裡的句型
        var replacesLibrary: Bool
        var included = true
    }

    var deck: String
    var items: [Item]
    var rejected: [(pattern: String, reason: String)]
    var updateLibrary: Bool
    var state: ProposalState = .pending

    static func == (a: PatternProposal, b: PatternProposal) -> Bool {
        a.deck == b.deck && a.items == b.items && a.state == b.state && a.updateLibrary == b.updateLibrary
            && a.rejected.map(\.pattern) == b.rejected.map(\.pattern)
    }
}

struct LearningCard: Equatable {
    struct Number: Equatable, Identifiable {
        var title: String
        var value: String
        var id: String { title }
    }

    struct Word: Equatable, Identifiable {
        var word: String
        var zh: String
        var memory: String
        var id: String { word }
    }

    var title: String
    var numbers: [Number]
    /// 每天的複習量（analyze_learning）
    var daily: [Int]
    var words: [Word]
}

struct PDFCard: Equatable {
    var url: URL
    var title: String
    var pages: Int
    var thumbnail: Data?
}

/// 使用者對確認卡的決定
enum ConfirmDecision: Equatable {
    case confirm
    case cancel
}
