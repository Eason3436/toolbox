import Foundation
import SwiftData

/// 傳給後端的學習紀錄（ios_push_snapshot）。Claude 連接器的 overview／analyze_learning／list_words 用這份計算。
/// 只傳學過的卡（加上自訂牌組的全部卡）和最近 90 天的複習，沒學過的單字庫卡只傳張數
struct StudySnapshot: Encodable {
    struct DeckRow: Encodable {
        let id: String
        let name: String
        let kind: String
        let category: String
        let mode: String
        let level: Int?
        let dailyNewLimit: Int
        let total: Int
        let new: Int
        let learning: Int
        let review: Int
        let mastered: Int
    }

    struct CardRow: Encodable {
        let id: String
        /// 原本的牌組
        let deck: String?
        /// 所在的所有牌組（原本的在最前面）；一張卡可以在好幾個牌組，進度只有一份
        let decks: [String]
        let word: String
        let pos: String?
        let zh: String
        let source: String
        let state: String
        let due: Date
        let stability: Double
        let difficulty: Double
        let reps: Int
        let lapses: Int
        let lastReview: Date?
    }

    struct LogRow: Encodable {
        /// card id
        let c: String
        /// 1 不會、2 模糊、3 認識、4 很熟
        let r: Int
        /// 評分前的狀態：new／learning／review／relearning
        let s: String
        let t: Date
        /// 排到幾天後
        let d: Double
    }

    let v = 1
    let generatedAt: Date
    let appVersion: String
    let timeZone: String
    let dailyNewLimit: Int
    let decks: [DeckRow]
    let cards: [CardRow]
    /// App 裡所有的卡（含還沒背的單字庫卡）的 id：判斷送來的字 App 裡是不是已經有卡
    let cardIds: [String]
    let logs: [LogRow]

    static let logDays = 90

    @MainActor
    static func make(context mainContext: ModelContext, now: Date = Date()) throws -> StudySnapshot {
        // 複習頁用自己的 context 存檔，主 context 裡已載入的卡可能還是舊值，所以另開一個讀最新的
        let context = ModelContext(mainContext.container)
        let decks = try context.fetch(FetchDescriptor<Deck>(sortBy: [SortDescriptor(\.sortIndex)]))
        var deckRows: [DeckRow] = []
        var cardRows: [CardRow] = []
        var listed: Set<String> = []
        var allIDs: [String] = []
        for deck in decks {
            let cards = deck.activeCards
            var new = 0, learning = 0, review = 0, mastered = 0
            for card in cards {
                switch card.state {
                case .new: new += 1
                case .learning, .relearning: learning += 1
                case .review: review += 1
                }
                if card.isMastered { mastered += 1 }
                // 同一張卡在好幾個牌組：只傳一次，decks 列出全部
                guard listed.insert(card.id).inserted else { continue }
                allIDs.append(card.id)
                let inCustomDeck = card.allDecks.contains { $0.kind == .custom }
                guard !card.isNew || inCustomDeck else { continue }
                cardRows.append(CardRow(
                    id: card.id, deck: card.deck?.id ?? deck.id, decks: card.allDecks.map(\.id),
                    word: card.word, pos: card.pos, zh: card.zh,
                    source: card.source.rawValue, state: card.state.name, due: card.due,
                    stability: card.stability, difficulty: card.difficulty,
                    reps: card.reps, lapses: card.lapses, lastReview: card.lastReview
                ))
            }
            deckRows.append(DeckRow(
                id: deck.id, name: deck.name, kind: deck.kind.rawValue, category: deck.category.rawValue,
                mode: deck.mode.rawValue, level: deck.level, dailyNewLimit: deck.dailyNewLimit,
                total: cards.count, new: new, learning: learning, review: review, mastered: mastered
            ))
        }

        let since = Calendar.current.date(byAdding: .day, value: -logDays, to: now) ?? now
        let logs = try context.fetch(FetchDescriptor<ReviewLog>(
            predicate: #Predicate { $0.reviewedAt >= since },
            sortBy: [SortDescriptor(\.reviewedAt)]
        ))
        let logRows = logs.map {
            LogRow(c: $0.cardId, r: $0.rating, s: (FSRSState(rawValue: $0.stateBeforeRaw) ?? .new).name, t: $0.reviewedAt, d: $0.scheduledDays)
        }

        return StudySnapshot(
            generatedAt: now,
            appVersion: AppConfig.shortVersion,
            timeZone: TimeZone.current.identifier,
            dailyNewLimit: UserDefaults.standard.object(forKey: SettingsKey.dailyNewLimit) as? Int ?? AppDefaults.dailyNewLimit,
            decks: deckRows,
            cards: cardRows,
            cardIds: allIDs,
            logs: logRows
        )
    }

    /// {"p_code": "...", "p_payload": {...}}，key 用 snake_case、時間用 ISO 8601
    static func requestBody(code: String, snapshot: StudySnapshot) throws -> Data {
        struct Body: Encodable {
            let pCode: String
            let pPayload: StudySnapshot
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Body(pCode: code, pPayload: snapshot))
    }
}

extension FSRSState {
    /// 傳給後端的名稱
    var name: String {
        switch self {
        case .new: "new"
        case .learning: "learning"
        case .review: "review"
        case .relearning: "relearning"
        }
    }
}

extension Notification.Name {
    /// 複習頁存檔了（RootView 收到就上傳學習紀錄）
    static let studyProgressSaved = Notification.Name("EnRecall.studyProgressSaved")
}
