import Foundation
import Observation
import SwiftData

/// 首頁、牌組頁的今日數字。
///
/// 卡片讀成簡單的值（`StudyForecast.Item`）存起來，只有卡片、連結或複習紀錄存檔時才重讀；
/// 暫停、每天新卡這種牌組設定只重算數字，不用再把幾千張卡從 SwiftData 讀一遍，按鈕才不會卡。
@MainActor
@Observable
final class StudySummaryCache {
    /// 卡片或複習紀錄存檔過就加一；畫面讀它，所以存檔後會重畫
    private var revision = 0
    @ObservationIgnored private var loadedRevision = -1
    @ObservationIgnored private var loadedDecks: Set<String> = []
    @ObservationIgnored private var items: [String: [StudyForecast.Item]] = [:]

    init() {
        // 這個物件跟著 App 的頁面一直活著，不另外移除觀察
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            guard Self.touchesCards(note) else { return }
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    func summary(decks: [Deck], logs: [ReviewLog], globalNewLimit: Int, now: Date = Date()) -> StudySummary {
        let ids = Set(decks.map(\.id))
        if revision != loadedRevision || ids != loadedDecks {
            // 暫停的牌組也讀：按繼續時不用重讀
            items = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, StudyForecast.items(of: $0)) })
            loadedRevision = revision
            loadedDecks = ids
        }
        let forecast = StudyForecast(
            decks: decks.sorted { $0.sortIndex < $1.sortIndex }.map { deck in
                StudyForecast.DeckItems(id: deck.id, mode: deck.mode, dailyNewLimit: deck.dailyNewLimit,
                                        newCardsAll: deck.newCardsAll, cards: items[deck.id] ?? [])
            },
            todayLogs: StudyPlanner.todaysLogs(logs, now: now),
            newLimit: globalNewLimit,
            now: now
        )
        return forecast.summary(at: now)
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
