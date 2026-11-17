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
    }

    struct DeckItems {
        let id: String
        let mode: DeckMode
        let dailyNewLimit: Int
        let cards: [Item]
    }

    let decks: [DeckItems]
    /// 今天的複習紀錄（算今天已經學了幾個新字）
    let todayLogs: [ReviewLog]
    let newLimit: Int
    let now: Date

    @MainActor
    static func load(context: ModelContext, now: Date = Date(), calendar: Calendar = .current) -> StudyForecast {
        let start = calendar.startOfDay(for: now)
        let decks = ((try? context.fetch(FetchDescriptor<Deck>())) ?? [])
            .sorted { $0.sortIndex < $1.sortIndex }
            .filter { $0.mode != .paused }
            .map { deck in
                DeckItems(id: deck.id, mode: deck.mode, dailyNewLimit: deck.dailyNewLimit,
                          cards: deck.orderedActiveCards.map { Item(id: $0.id, isNew: $0.isNew, due: $0.due) })
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
        // 今天學過的新字只算在今天；明天起額度重來
        let newToday = calendar.isDate(date, inSameDayAs: now) ? todayLogs.filter(\.wasNew) : []
        var doneByDeck: [String: Int] = [:]
        for log in newToday { doneByDeck[log.deckId ?? "", default: 0] += 1 }
        var remaining = max(0, newLimit - newToday.count)

        var counts = StudyCounts()
        var counted: Set<String> = []
        for deck in decks {
            let cards = deck.cards.filter { !counted.contains($0.id) }
            for card in cards where !card.isNew && card.due <= date {
                counts.due += 1
                counted.insert(card.id)
            }
            guard deck.mode == .active, remaining > 0 else { continue }
            let allowance = min(remaining, max(0, deck.dailyNewLimit - doneByDeck[deck.id, default: 0]))
            let picked = Array(cards.filter(\.isNew).prefix(allowance))
            for card in picked { counted.insert(card.id) }
            counts.new += picked.count
            remaining -= picked.count
        }
        return counts
    }
}
