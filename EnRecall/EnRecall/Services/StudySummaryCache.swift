import Foundation
import Observation
import SwiftData

/// 首頁、牌組頁、紀錄頁共用的數字（整個 App 一份，放在 environment）。
///
/// 卡片讀成簡單的值（`StudyForecast.Item`）、複習紀錄濃縮成每天幾張，存起來重複用；
/// 只有卡片、連結或複習紀錄存檔時才重讀，而且只重讀畫面要用到的牌組。
/// 按鈕、切分頁、推頁面時畫面會重畫，重畫只用存好的值，不再把幾千張卡、幾千筆紀錄從 SwiftData 讀一遍。
@MainActor
@Observable
final class StudySummaryCache {
    /// 卡片或複習紀錄存檔過就加一；畫面讀它，所以存檔後會重畫
    private var revision = 0
    @ObservationIgnored private var items: [String: [StudyForecast.Item]] = [:]
    @ObservationIgnored private var itemsRevision: [String: Int] = [:]
    @ObservationIgnored private var digest = LogDigest()
    @ObservationIgnored private var digestRevision = -1

    init() {
        // 這個物件跟著 App 一直活著，不另外移除觀察
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            guard Self.touchesCards(note) else { return }
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    /// 一個牌組的卡（照牌組順序、停用的不算）；過期了才重讀
    private func cards(of deck: Deck) -> [StudyForecast.Item] {
        if itemsRevision[deck.id] != revision || items[deck.id] == nil {
            items[deck.id] = StudyForecast.items(of: deck)
            itemsRevision[deck.id] = revision
        }
        return items[deck.id] ?? []
    }

    func summary(decks: [Deck], logs: [ReviewLog], globalNewLimit: Int, now: Date = Date()) -> StudySummary {
        let forecast = StudyForecast(
            decks: decks.sorted { $0.sortIndex < $1.sortIndex }.map { deck in
                // 暫停的牌組也讀：按繼續時不用重讀
                StudyForecast.DeckItems(id: deck.id, mode: deck.mode, dailyNewLimit: deck.dailyNewLimit,
                                        newCardsAll: deck.newCardsAll, cards: cards(of: deck))
            },
            todayLogs: StudyPlanner.todaysLogs(logs, now: now),
            newLimit: globalNewLimit,
            now: now
        )
        return forecast.summary(at: now)
    }

    /// 牌組卡、紀錄頁熟練度用的張數
    func counts(of deck: Deck) -> DeckCounts {
        var counts = DeckCounts()
        for item in cards(of: deck) {
            counts.total += 1
            if item.isMastered {
                counts.mastered += 1
            } else if item.isNew {
                counts.fresh += 1
            }
        }
        return counts
    }

    /// 複習紀錄濃縮成每天幾張（連續天數、熱力圖、每日長條）
    func logDigest(context: ModelContext) -> LogDigest {
        if digestRevision != revision {
            digest = LogDigest(context: context)
            digestRevision = revision
        }
        return digest
    }

    /// 只改了牌組設定（或單字內容）的存檔不用重讀卡片；看不懂的通知當作有變
    nonisolated private static func touchesCards(_ note: Notification) -> Bool {
        guard let info = note.userInfo else { return true }
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        var understood = false
        for key in keys {
            guard let ids = info[key.rawValue] as? [PersistentIdentifier] else { continue }
            understood = true
            if ids.contains(where: { $0.entityName != "Deck" && $0.entityName != "CardContent" }) { return true }
        }
        return !understood
    }
}

/// 一個牌組的張數
struct DeckCounts {
    var total = 0
    var mastered = 0
    var fresh = 0

    var learned: Int { total - fresh }
    var learning: Int { total - mastered - fresh }
}

/// 複習紀錄的每日張數（只留日期和張數，不留 ReviewLog 物件）
struct LogDigest {
    /// 那天的開始 → 複習幾張
    private(set) var reviews: [Date: Int] = [:]
    /// 那天的開始 → 其中新學幾張
    private(set) var learned: [Date: Int] = [:]

    init() {}

    @MainActor
    init(context: ModelContext, calendar: Calendar = .current) {
        var descriptor = FetchDescriptor<ReviewLog>()
        descriptor.propertiesToFetch = [\.reviewedAt, \.stateBeforeRaw]
        let logs = (try? context.fetch(descriptor)) ?? []
        for log in logs {
            let day = calendar.startOfDay(for: log.reviewedAt)
            reviews[day, default: 0] += 1
            if log.wasNew { learned[day, default: 0] += 1 }
        }
    }

    func reviewCount(on date: Date, calendar: Calendar = .current) -> Int {
        reviews[calendar.startOfDay(for: date)] ?? 0
    }

    func learnedCount(on date: Date, calendar: Calendar = .current) -> Int {
        learned[calendar.startOfDay(for: date)] ?? 0
    }

    /// 連續天數：今天還沒背就從昨天算起
    func streak(now: Date = Date(), calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: now)
        if reviews[day] == nil {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while reviews[day] != nil {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    /// 最近幾天每天幾張，最舊的在前
    func dailyCounts(days: Int, now: Date = Date(), calendar: Calendar = .current) -> [DayCount] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - (days - 1), to: today) else { return nil }
            return DayCount(date: date, count: reviews[date] ?? 0)
        }
    }
}
