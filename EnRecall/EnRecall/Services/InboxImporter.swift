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

    enum CodingKeys: String, CodingKey {
        case id, word, pos, zh, example, source
        case deckName = "deck_name"
        case exampleZh = "example_zh"
        case libraryWordId = "library_word_id"
    }
}

struct ImportResult: Equatable {
    var added = 0
    var skipped = 0
    /// 有新增卡片的牌組名稱（依第一次出現的順序）
    var decks: [String] = []

    mutating func merge(_ other: ImportResult) {
        added += other.added
        skipped += other.skipped
        for deck in other.decks where !decks.contains(deck) { decks.append(deck) }
    }

    var toastMessage: String? {
        guard added > 0 || skipped > 0 else { return nil }
        if added == 0 {
            return "從 Claude 送來的 \(skipped) 個單字都已經有了"
        }
        var text: String
        if decks.count == 1, let deck = decks.first {
            text = "從 Claude 匯入 \(added) 個單字到〈\(deck)〉"
        } else {
            text = "從 Claude 匯入 \(added) 個單字"
        }
        if skipped > 0 { text += "，略過 \(skipped) 個重複" }
        return text
    }
}

/// 把收件匣的字放進牌組（規劃書 5.5）：
/// - 依 deck_name 找自訂牌組，沒有就建立
/// - 單字庫的字（library_word_id）已經在本機任何牌組 → 跳過，不重複、不重置進度
/// - 同一牌組內 wordNorm + 詞性相同 → 跳過
/// - 其他建立新卡（FSRS 狀態是新卡）
enum InboxImporter {
    @MainActor
    static func importItems(_ items: [InboxItem], into context: ModelContext, now: Date = Date()) throws -> ImportResult {
        guard !items.isEmpty else { return ImportResult() }

        let decks = try context.fetch(FetchDescriptor<Deck>())
        var nextDeckIndex = (decks.map(\.sortIndex).max() ?? -1) + 1
        var customDecks: [String: Deck] = [:]
        for deck in decks where deck.kind == .custom {
            customDecks[deck.name] = customDecks[deck.name] ?? deck
        }
        var existingIDs = Set(try context.fetch(FetchDescriptor<Card>()).map(\.id))

        var result = ImportResult()
        var deckKeys: [String: Set<String>] = [:]
        var deckNextIndex: [String: Int] = [:]

        for item in items {
            let deckName = item.deckName.trimmingCharacters(in: .whitespacesAndNewlines)
            let word = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let zh = item.zh.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deckName.isEmpty, !word.isEmpty, !zh.isEmpty else {
                result.skipped += 1
                continue
            }

            let deck: Deck
            if let found = customDecks[deckName] {
                deck = found
            } else {
                deck = Deck(id: "custom:" + UUID().uuidString, name: deckName, kind: .custom, sortIndex: nextDeckIndex, createdAt: now)
                nextDeckIndex += 1
                context.insert(deck)
                customDecks[deckName] = deck
            }

            if deckKeys[deck.id] == nil {
                deckKeys[deck.id] = Set(deck.cards.map { key(word: $0.wordNorm, pos: $0.pos) })
                deckNextIndex[deck.id] = (deck.cards.map(\.sortIndex).max() ?? -1) + 1
            }

            let libraryID = item.libraryWordId.flatMap { $0.isEmpty ? nil : $0 }
            let dedupKey = key(word: Normalizer.normalize(word), pos: item.pos)
            if let libraryID, existingIDs.contains(libraryID) {
                result.skipped += 1
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

            existingIDs.insert(id)
            deckKeys[deck.id, default: []].insert(dedupKey)
            deckNextIndex[deck.id] = sortIndex + 1
            result.added += 1
            if !result.decks.contains(deck.name) { result.decks.append(deck.name) }
        }

        try context.save()
        return result
    }

    static func key(word: String, pos: String?) -> String {
        word + "|" + Normalizer.normalize(pos ?? "")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
