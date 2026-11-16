import Foundation
import SwiftData

/// PDF 的用途（跟 Android 版一樣）
enum HandoutKind: String, CaseIterable, Identifiable {
    /// 講義：一字一列，字義、例句、延伸
    case notes
    /// 自測卷：一題一列＋答案線，答案在最後一頁
    case test
    /// 速查表：四欄，一行一字
    case sheet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "講義"
        case .test: "自測卷"
        case .sheet: "速查表"
        }
    }

    var subtitle: String {
        switch self {
        case .notes: "讀：完整字義、例句、搭配"
        case .test: "考：看中文寫英文，答案在最後一頁"
        case .sheet: "查：考前快速掃過，一頁約 120 字"
        }
    }
}

/// 要印哪些字
enum HandoutRange: String, CaseIterable, Identifiable {
    /// 背過的字裡記得的機率最低的
    case weakest
    /// 今天複習過的
    case today
    /// 最近 7 天複習過的
    case recent
    /// 某個牌組（照牌組的順序，含還沒背的）
    case deck

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weakest: "最常忘"
        case .today: "今天背的"
        case .recent: "最近 7 天"
        case .deck: "牌組"
        }
    }
}

/// 份量（講義才有差別）
enum HandoutAmount: String, CaseIterable, Identifiable {
    case brief
    case standard
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: "精簡"
        case .standard: "標準"
        case .full: "完整"
        }
    }
}

/// 自測卷的方向
enum HandoutDirection: String, CaseIterable, Identifiable {
    case zhToEn
    case enToZh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zhToEn: "中→英"
        case .enToZh: "英→中"
        }
    }
}

struct HandoutOptions: Equatable {
    var kind: HandoutKind = .notes
    var range: HandoutRange = .weakest
    var deckID: String?
    var count = 30
    var amount: HandoutAmount = .standard
    var direction: HandoutDirection = .zhToEn
}

/// PDF 上的一個字
struct HandoutEntry {
    let card: Card
    let detail: CardDetail?
    /// 現在記得的機率（0–1）；還沒背過是 nil
    let recall: Double?

    var isPattern: Bool { detail?.pattern != nil || card.deck?.category == .pattern }
    var isPhrase: Bool { !isPattern && (detail?.phrase != nil || card.deck?.category == .phrase) }

    /// ●●●○○；還沒背過是「新字」
    var memoryText: String {
        guard let recall else { return "新字" }
        let filled = min(5, max(0, Int((recall * 5).rounded())))
        return String(repeating: "●", count: filled) + String(repeating: "○", count: 5 - filled)
    }

    /// 學測級別（L1–L6）
    var levelText: String? { card.deck?.level.map { "L\($0)" } }
}

enum HandoutBuilder {
    /// 範圍的說明（頁首、頁尾）
    @MainActor
    static func rangeTitle(_ options: HandoutOptions, context: ModelContext) -> String {
        if options.range == .deck, let deck = deck(options.deckID, context: context) { return deck.name }
        return options.range.title
    }

    @MainActor
    static func entries(_ options: HandoutOptions, context: ModelContext, now: Date = Date()) throws -> [HandoutEntry] {
        let scheduler = FSRSScheduler()
        func recall(_ card: Card) -> Double? {
            guard !card.isNew else { return nil }
            let elapsed = card.lastReview.map { now.timeIntervalSince($0) / 86_400 } ?? 0
            return scheduler.retrievability(elapsedDays: max(elapsed, 0), stability: card.stability)
        }

        var cards: [Card]
        switch options.range {
        case .deck:
            cards = deck(options.deckID, context: context)?.orderedActiveCards ?? []
        case .weakest:
            cards = try allCards(context).filter { !$0.isNew }
        case .today, .recent:
            let days = options.range == .today ? 0 : 6
            let start = Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: now)) ?? now
            let logs = try context.fetch(FetchDescriptor<ReviewLog>(predicate: #Predicate { $0.reviewedAt >= start }))
            let ids = Set(logs.map(\.cardId))
            cards = try allCards(context).filter { ids.contains($0.id) }
        }
        if options.range != .deck {
            // 記得的機率低的先印
            cards.sort { (recall($0) ?? 0) < (recall($1) ?? 0) }
        }
        // 自測卷不出句型（沒有單一答案）
        if options.kind == .test {
            cards = cards.filter { $0.deck?.category != .pattern }
        }

        return cards.prefix(options.count).map { card in
            HandoutEntry(card: card, detail: CardDetail.load(for: card.id, in: context), recall: recall(card))
        }
    }

    @MainActor
    private static func allCards(_ context: ModelContext) throws -> [Card] {
        var seen: Set<String> = []
        return try context.fetch(FetchDescriptor<Card>())
            .filter { !$0.isRetired && seen.insert($0.id).inserted }
    }

    @MainActor
    private static func deck(_ id: String?, context: ModelContext) -> Deck? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Deck>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
