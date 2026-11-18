import Foundation
import SwiftData

/// ios_claim_inbox 回傳的一筆
struct InboxItem: Codable, Equatable {
    let id: String
    let deckName: String
    let word: String
    let pos: String?
    let zh: String
    let example: String?
    let exampleZh: String?
    let source: String
    let libraryWordId: String?
    /// word（預設）或 pattern
    var kind: String?
    /// 句型卡的完整內容（kind = pattern）
    var detail: PatternDetail?

    var isPattern: Bool { kind == "pattern" }

    enum CodingKeys: String, CodingKey {
        case id, word, pos, zh, example, source, kind, detail
        case deckName = "deck_name"
        case exampleZh = "example_zh"
        case libraryWordId = "library_word_id"
    }

    init(id: String, deckName: String, word: String, pos: String?, zh: String, example: String?, exampleZh: String?,
         source: String, libraryWordId: String?, kind: String? = nil, detail: PatternDetail? = nil) {
        self.id = id
        self.deckName = deckName
        self.word = word
        self.pos = pos
        self.zh = zh
        self.example = example
        self.exampleZh = exampleZh
        self.source = source
        self.libraryWordId = libraryWordId
        self.kind = kind
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        deckName = try c.decode(String.self, forKey: .deckName)
        word = try c.decode(String.self, forKey: .word)
        pos = c.lenient(.pos)
        zh = try c.decode(String.self, forKey: .zh)
        example = c.lenient(.example)
        exampleZh = c.lenient(.exampleZh)
        source = try c.decode(String.self, forKey: .source)
        libraryWordId = c.lenient(.libraryWordId)
        kind = c.lenient(.kind)
        // 句型內容格式不對就只匯入公式和中文，不要整批失敗
        detail = c.lenient(.detail)
    }
}

struct ImportResult: Equatable {
    var added = 0
    /// added 裡面有幾個是句型
    var patterns = 0
    /// added 裡面有幾個是 App 裡本來就有的卡，只是放進這個牌組（進度照舊）
    var linked = 0
    var skipped = 0
    /// 有新增卡片的牌組名稱（依第一次出現的順序）
    var decks: [String] = []

    mutating func merge(_ other: ImportResult) {
        added += other.added
        patterns += other.patterns
        linked += other.linked
        skipped += other.skipped
        for deck in other.decks where !decks.contains(deck) { decks.append(deck) }
    }

    var toastMessage: String? {
        guard added > 0 || skipped > 0 else { return nil }
        if added == 0 {
            return "從 Claude 送來的 \(skipped) 個都已經有了"
        }
        let words = added - patterns
        let what: String
        if patterns == 0 {
            what = "\(added) 個單字"
        } else if words == 0 {
            what = "\(patterns) 個句型"
        } else {
            what = "\(words) 個單字和 \(patterns) 個句型"
        }
        var text: String
        if decks.count == 1, let deck = decks.first {
            text = "從 Claude 匯入 \(what)到〈\(deck)〉"
        } else {
            text = "從 Claude 匯入 \(what)"
        }
        if linked > 0 { text += "，其中 \(linked) 個本來就在背，進度照舊" }
        if skipped > 0 { text += "，略過 \(skipped) 個重複" }
        return text
    }
}

/// 把收件匣的字放進牌組（規劃書 5.5）：
/// - 依 deck_name 找自訂牌組，沒有就建立
/// - 單字庫的字（library_word_id）已經在本機別的牌組 → 連到這個牌組（DeckLink），不建新卡、進度照舊
/// - 已經在這個牌組 → 跳過
/// - 同一牌組內 wordNorm + 詞性相同 → 跳過
/// - 其他建立新卡（FSRS 狀態是新卡）
enum InboxImporter {
    @MainActor
    static func importItems(_ items: [InboxItem], into context: ModelContext, now: Date = Date()) throws -> ImportResult {
        guard !items.isEmpty else { return ImportResult() }

        let decks = try context.fetch(FetchDescriptor<Deck>())
        var nextDeckIndex = (decks.map(\.sortIndex).max() ?? -1) + 1
        // 同名的單字牌組和句型牌組分開
        var customDecks: [String: Deck] = [:]
        for deck in decks where deck.kind == .custom {
            let key = deckKey(deck.name, deck.category)
            customDecks[key] = customDecks[key] ?? deck
        }
        var existing: [String: Card] = [:]
        for card in try context.fetch(FetchDescriptor<Card>()) { existing[card.id] = card }

        var result = ImportResult()
        var deckKeys: [String: Set<String>] = [:]
        var deckNextIndex: [String: Int] = [:]
        // 這一批剛連好的（還沒存檔，deck.links 不一定看得到）
        var linkedHere: Set<String> = []

        for item in items {
            let deckName = item.deckName.trimmingCharacters(in: .whitespacesAndNewlines)
            let word = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let zh = item.zh.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deckName.isEmpty, !word.isEmpty, !zh.isEmpty else {
                result.skipped += 1
                continue
            }

            let category: DeckCategory = item.isPattern ? .pattern : .word
            let deck: Deck
            if let found = customDecks[deckKey(deckName, category)] {
                deck = found
            } else {
                deck = Deck(id: "custom:" + UUID().uuidString, name: deckName, kind: .custom, category: category,
                            sortIndex: nextDeckIndex, createdAt: now)
                // 雜誌、課本的字一次背完，不分每天幾個
                deck.newCardsAll = true
                nextDeckIndex += 1
                context.insert(deck)
                customDecks[deckKey(deckName, category)] = deck
            }

            if deckKeys[deck.id] == nil {
                deckKeys[deck.id] = Set(deck.allCards.map { key(word: $0.wordNorm, pos: $0.pos) })
                deckNextIndex[deck.id] = deck.nextSortIndex
            }

            let libraryID = item.libraryWordId.flatMap { $0.isEmpty ? nil : $0 }
            let dedupKey = key(word: Normalizer.normalize(word), pos: item.pos)
            if let libraryID, let card = existing[libraryID] {
                // 已經有的句型：內容換成新的（Claude 可能補充過），進度不動
                if let detail = item.detail {
                    try saveContent(CardDetail(word: nil, phrase: nil, similar: nil, pattern: detail), id: libraryID, in: context)
                }
                guard !deck.contains(card), !linkedHere.contains(DeckLink.key(deckID: deck.id, cardID: card.id)) else {
                    result.skipped += 1
                    continue
                }
                // 在別的牌組：連過來，同一張卡、同一份進度
                let sortIndex = deckNextIndex[deck.id] ?? 0
                DeckLink.insert(deck: deck, card: card, sortIndex: sortIndex, addedAt: now, into: context)
                linkedHere.insert(DeckLink.key(deckID: deck.id, cardID: card.id))
                deck.lastImportedAt = now
                deckKeys[deck.id, default: []].insert(key(word: card.wordNorm, pos: card.pos))
                deckNextIndex[deck.id] = sortIndex + 1
                if item.isPattern { result.patterns += 1 }
                result.added += 1
                result.linked += 1
                if !result.decks.contains(deck.name) { result.decks.append(deck.name) }
                continue
            }
            if deckKeys[deck.id]?.contains(dedupKey) == true {
                result.skipped += 1
                continue
            }

            let source: CardSource = (item.source == "library" && libraryID != nil) ? .library : .claude
            let id = libraryID ?? ("claude:" + UUID().uuidString)
            let sortIndex = deckNextIndex[deck.id] ?? 0
            let card = Card(
                id: id,
                word: word,
                pos: nonEmpty(item.pos),
                zh: zh,
                example: nonEmpty(item.example),
                exampleZh: nonEmpty(item.exampleZh),
                source: source,
                sortIndex: sortIndex,
                addedAt: now
            )
            card.deck = deck
            context.insert(card)
            deck.lastImportedAt = now
            if let detail = item.detail {
                try saveContent(CardDetail(word: nil, phrase: nil, similar: nil, pattern: detail), id: id, in: context)
            }
            if item.isPattern { result.patterns += 1 }

            existing[id] = card
            deckKeys[deck.id, default: []].insert(dedupKey)
            deckNextIndex[deck.id] = sortIndex + 1
            result.added += 1
            if !result.decks.contains(deck.name) { result.decks.append(deck.name) }
        }

        try context.save()
        return result
    }

    private static func deckKey(_ name: String, _ category: DeckCategory) -> String {
        category.rawValue + "|" + name
    }

    @MainActor
    private static func saveContent(_ detail: CardDetail, id: String, in context: ModelContext) throws {
        let data = try JSONEncoder().encode(detail)
        var descriptor = FetchDescriptor<CardContent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.data = data
        } else {
            context.insert(CardContent(id: id, data: data))
        }
    }

    static func key(word: String, pos: String?) -> String {
        word + "|" + Normalizer.normalize(pos ?? "")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
