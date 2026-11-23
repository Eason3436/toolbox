import Foundation
import SwiftData

/// 預估之後某個時間點還有多少要背（假設中間都沒有再背）：通知和桌面小工具用。
/// 跟 StudyPlanner 同一套規則（暫停的牌組不出卡、只複習的牌組不出新字、全部上限＋各牌組上限、同一張卡只算一次），
/// 但卡片先讀成簡單的值，算十幾個時間點也很快（App 進背景時只有幾秒）
struct StudyForecast {
    struct Item {
        let id: String
        let isNew: Bool
        let due: Date
        /// 卡片原本牌組的類型（首頁、牌組頁分記憶卡／片語卡／句型卡）
        var category: DeckCategory = .word
        /// 已熟悉（紀錄頁的熟練度用）
        var isMastered: Bool = false
    }

    struct DeckItems {
        let id: String
        let mode: DeckMode
        let dailyNewLimit: Int
        var newCardsAll: Bool = false
        let cards: [Item]
    }

    /// 依牌組順序排好（暫停的牌組在 summary 裡跳過）
    let decks: [DeckItems]
    /// 今天的複習紀錄（算今天已經學了幾個新字）
    let todayLogs: [ReviewLog]
    let newLimit: Int
    let now: Date

    /// 一個牌組的卡讀成簡單的值（照牌組自己的順序，停用的不算）
    @MainActor
    static func items(of deck: Deck) -> [Item] {
        deck.orderedActiveCards.map {
            Item(id: $0.id, isNew: $0.isNew, due: $0.due, category: $0.deck?.category ?? deck.category,
                 isMastered: $0.isMastered)
        }
    }

    @MainActor
    static func load(context: ModelContext, now: Date = Date(), calendar: Calendar = .current) -> StudyForecast {
        let start = calendar.startOfDay(for: now)
        let decks = ((try? context.fetch(FetchDescriptor<Deck>())) ?? [])
            .sorted { $0.sortIndex < $1.sortIndex }
            .filter { $0.mode != .paused }
            .map { deck in
                DeckItems(id: deck.id, mode: deck.mode, dailyNewLimit: deck.dailyNewLimit,
                          newCardsAll: deck.newCardsAll, cards: items(of: deck))
            }
        let logs = (try? context.fetch(FetchDescriptor<ReviewLog>(predicate: #Predicate { $0.reviewedAt >= start }))) ?? []
        let defaults = UserDefaults.standard
        let limit = defaults.object(forKey: SettingsKey.dailyNewLimit) == nil
            ? AppDefaults.dailyNewLimit
            : defaults.integer(forKey: SettingsKey.dailyNewLimit)
        return StudyForecast(decks: decks, todayLogs: logs, newLimit: limit, now: now)
    }

    /// 那個時間點：到期的複習卡＋那天還能學的新字
    func counts(at date: Date, calendar: Calendar = .current) -> StudyCounts {
        summary(at: date, calendar: calendar).all
    }

    /// 跟 StudyPlanner.summary 一樣的數字，但不用碰 SwiftData
    func summary(at date: Date, calendar: Calendar = .current) -> StudySummary {
        // 今天學過的新字只算在今天；明天起額度重來
        let newToday = calendar.isDate(date, inSameDayAs: now) ? todayLogs.filter(\.wasNew) : []
        var doneByDeck: [String: Int] = [:]
        for log in newToday { doneByDeck[log.deckId ?? "", default: 0] += 1 }
        let unlimited = Set(decks.filter(\.newCardsAll).map(\.id))
        let limitedDone = newToday.filter { !unlimited.contains($0.deckId ?? "") }.count
        var remaining = max(0, newLimit - limitedDone)

        var summary = StudySummary()
        summary.newDoneToday = limitedDone
        summary.newLimit = newLimit
        var counted: Set<String> = []
        for deck in decks where deck.mode != .paused {
            let cards = deck.cards.filter { !counted.contains($0.id) }
            for card in cards where !card.isNew && card.due <= date {
                summary.all.due += 1
                summary.byCategory[card.category, default: StudyCounts()].due += 1
                counted.insert(card.id)
            }
            guard deck.mode == .active else { continue }
            let allowance = deck.newCardsAll
                ? Int.max
                : min(remaining, max(0, deck.dailyNewLimit - doneByDeck[deck.id, default: 0]))
            guard allowance > 0 else { continue }
            let picked = cards.filter(\.isNew).prefix(allowance)
            for card in picked {
                counted.insert(card.id)
                summary.byCategory[card.category, default: StudyCounts()].new += 1
            }
            summary.all.new += picked.count
            if !deck.newCardsAll { remaining -= picked.count }
        }
        return summary
    }
}
