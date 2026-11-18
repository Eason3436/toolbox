import Foundation
import SwiftData

/// 一張卡也放在別的牌組（多對多）。
///
/// 卡片有一個「原本的牌組」（`Card.deck`：單字庫的字是等級牌組，Claude 寫的字是它第一次匯入的牌組），
/// 再放進別的牌組時只加一筆連結，卡片和複習進度都只有一份。
/// 從牌組移除只刪連結；原本的牌組不能移除，所以卡片永遠至少在一個牌組裡。
@Model
final class DeckLink {
    /// deckID|cardID，同一張卡在同一個牌組只有一筆
    @Attribute(.unique) var key: String
    var deck: Deck?
    var card: Card?
    /// 在這個牌組裡的順序（依序出新卡、牌組列表）
    var sortIndex: Int = 0
    var addedAt: Date = Date()

    init(deckID: String, cardID: String, sortIndex: Int, addedAt: Date = Date()) {
        self.key = Self.key(deckID: deckID, cardID: cardID)
        self.sortIndex = sortIndex
        self.addedAt = addedAt
    }

    /// 先放進 context 再接上關係（SwiftData 建議的順序）
    @discardableResult
    static func insert(deck: Deck, card: Card, sortIndex: Int, addedAt: Date = Date(), into context: ModelContext) -> DeckLink {
        let link = DeckLink(deckID: deck.id, cardID: card.id, sortIndex: sortIndex, addedAt: addedAt)
        context.insert(link)
        link.deck = deck
        link.card = card
        return link
    }

    static func key(deckID: String, cardID: String) -> String {
        deckID + "|" + cardID
    }
}

extension Deck {
    /// 牌組裡所有的卡（原本就在這裡的＋連過來的），同一張卡只出現一次
    var allCards: [Card] {
        var seen = Set(cards.map(\.id))
        var result = cards
        for link in links {
            guard let card = link.card, seen.insert(card.id).inserted else { continue }
            result.append(card)
        }
        return result
    }

    /// 這張卡在這個牌組裡的順序
    func sortIndex(of card: Card) -> Int {
        if card.deck?.id == id { return card.sortIndex }
        return links.first { $0.card?.id == card.id }?.sortIndex ?? card.sortIndex
    }

    /// 依這個牌組的順序排好的卡（停用的不算）
    var orderedActiveCards: [Card] {
        var order: [String: Int] = [:]
        for card in cards { order[card.id] = card.sortIndex }
        for link in links {
            guard let card = link.card, order[card.id] == nil else { continue }
            order[card.id] = link.sortIndex
        }
        return activeCards.sorted { (order[$0.id] ?? $0.sortIndex) < (order[$1.id] ?? $1.sortIndex) }
    }

    /// 下一張放進來的卡的順序
    var nextSortIndex: Int {
        max(cards.map(\.sortIndex).max() ?? -1, links.map(\.sortIndex).max() ?? -1) + 1
    }

    func contains(_ card: Card) -> Bool {
        card.deck?.id == id || links.contains { $0.card?.id == card.id }
    }

    /// 連結進來的卡（不是原本就在這裡的）
    func isLinked(_ card: Card) -> Bool {
        card.deck?.id != id && links.contains { $0.card?.id == card.id }
    }
}

extension Card {
    /// 卡片所在的所有牌組：原本的牌組在最前面
    var allDecks: [Deck] {
        var result: [Deck] = deck.map { [$0] } ?? []
        for link in links {
            guard let linked = link.deck, !result.contains(where: { $0.id == linked.id }) else { continue }
            result.append(linked)
        }
        return result
    }
}

enum DeckMembership {
    /// 把卡放進牌組。已經在了就不動，回傳 false
    @MainActor
    @discardableResult
    static func add(_ card: Card, to deck: Deck, in context: ModelContext, now: Date = Date()) -> Bool {
        guard !deck.contains(card) else { return false }
        DeckLink.insert(deck: deck, card: card, sortIndex: deck.nextSortIndex, addedAt: now, into: context)
        return true
    }

    /// 從牌組移除：只刪連結，卡片和進度都還在。原本的牌組不能移除
    @MainActor
    @discardableResult
    static func remove(_ card: Card, from deck: Deck, in context: ModelContext) -> Bool {
        guard deck.isLinked(card) else { return false }
        for link in deck.links where link.card?.id == card.id {
            context.delete(link)
        }
        return true
    }
}
