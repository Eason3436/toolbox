import Foundation
import SwiftData

@Model
final class Card {
    /// 單字庫：w:<單字>、p:<片語>（規則見 EnRecall/supabase/DEPLOY.md 第 4 節）；Claude 寫的字："claude:" + UUID
    @Attribute(.unique) var id: String
    var word: String
    var wordNorm: String
    var pos: String?
    var zh: String
    var example: String?
    var exampleZh: String?
    var phonetic: String?
    var sourceRaw: String = CardSource.library.rawValue
    /// 單字庫已刪除這個字：保留在本機（進度不丟），但不再出現在複習裡
    var isRetired: Bool = false
    /// 依序出新卡時的順序
    var sortIndex: Int = 0
    var addedAt: Date = Date()
    var deck: Deck?

    // FSRS 狀態
    var stateRaw: Int = FSRSState.new.rawValue
    var stability: Double = 0
    var difficulty: Double = 0
    var due: Date = Date()
    var lastReview: Date?
    var reps: Int = 0
    var lapses: Int = 0

    init(
        id: String,
        word: String,
        pos: String? = nil,
        zh: String,
        example: String? = nil,
        exampleZh: String? = nil,
        phonetic: String? = nil,
        source: CardSource = .library,
        sortIndex: Int = 0,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.word = word
        self.wordNorm = Normalizer.normalize(word)
        self.pos = pos
        self.zh = zh
        self.example = example
        self.exampleZh = exampleZh
        self.phonetic = phonetic
        self.sourceRaw = source.rawValue
        self.sortIndex = sortIndex
        self.addedAt = addedAt
    }

    var source: CardSource {
        get { CardSource(rawValue: sourceRaw) ?? .library }
        set { sourceRaw = newValue.rawValue }
    }

    var state: FSRSState {
        get { FSRSState(rawValue: stateRaw) ?? .new }
        set { stateRaw = newValue.rawValue }
    }

    var isNew: Bool { state == .new }

    /// 已熟悉：進入 review 狀態且穩定度至少 21 天
    var isMastered: Bool { state == .review && stability >= 21 }

    func isDue(at date: Date) -> Bool {
        !isNew && !isRetired && due <= date
    }
}
