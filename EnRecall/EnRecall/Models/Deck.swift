import Foundation
import SwiftData

@Model
final class Deck {
    /// 單字包：包 id（gsat-1、phrasebook）；自訂牌組："custom:" + UUID
    @Attribute(.unique) var id: String
    var name: String
    var kindRaw: String = DeckKind.custom.rawValue
    var categoryRaw: String = DeckCategory.word.rawValue
    var modeRaw: String = DeckMode.active.rawValue
    /// 暫停前是「出新卡」還是「只出複習」：按繼續就回到那個
    var resumeModeRaw: String = DeckMode.active.rawValue
    var orderRaw: String = NewCardOrder.sequential.rawValue
    /// 這個牌組每天最多出幾張新卡
    var dailyNewLimit: Int = 10
    /// 牌組頁的排序，也是領新卡的順序（小的先）
    var sortIndex: Int = 0
    /// 單字包版本（catalog.json 的 version）
    var packVersion: Int?
    /// 學測級別（1–6），片語和自訂牌組是 nil
    var level: Int?
    var createdAt: Date = Date()
    /// 最近一次從 Claude 匯入進來的時間（首頁「從 Claude 匯入」顯示最新的那個牌組）
    var lastImportedAt: Date?
    /// 安裝時的內容格式（PackInstaller.contentFormat）。比較舊就在背景重新安裝一次，進度不動
    var contentFormat: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Card.deck)
    var cards: [Card] = []

    /// 從別的牌組連過來的卡（DeckLink.swift）
    @Relationship(deleteRule: .cascade, inverse: \DeckLink.deck)
    var links: [DeckLink] = []

    init(
        id: String,
        name: String,
        kind: DeckKind,
        category: DeckCategory = .word,
        mode: DeckMode = .active,
        order: NewCardOrder = .sequential,
        dailyNewLimit: Int = 10,
        sortIndex: Int = 0,
        packVersion: Int? = nil,
        level: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.categoryRaw = category.rawValue
        self.modeRaw = mode.rawValue
        self.orderRaw = order.rawValue
        self.dailyNewLimit = dailyNewLimit
        self.sortIndex = sortIndex
        self.packVersion = packVersion
        self.level = level
        self.createdAt = createdAt
    }

    var kind: DeckKind {
        get { DeckKind(rawValue: kindRaw) ?? .custom }
        set { kindRaw = newValue.rawValue }
    }

    var category: DeckCategory {
        get { DeckCategory(rawValue: categoryRaw) ?? .word }
        set { categoryRaw = newValue.rawValue }
    }

    var mode: DeckMode {
        get { DeckMode(rawValue: modeRaw) ?? .active }
        set { modeRaw = newValue.rawValue }
    }

    /// 牌組卡旁邊的暫停鍵
    var isPaused: Bool {
        get { mode == .paused }
        set {
            guard newValue != isPaused else { return }
            if newValue {
                resumeModeRaw = modeRaw
                mode = .paused
            } else {
                let resume = DeckMode(rawValue: resumeModeRaw) ?? .active
                mode = resume == .paused ? .active : resume
            }
        }
    }

    /// 出新卡／只出複習（暫停時是按繼續之後會回到的那個）
    var runMode: DeckMode {
        get {
            guard isPaused else { return mode }
            let resume = DeckMode(rawValue: resumeModeRaw) ?? .active
            return resume == .paused ? .active : resume
        }
        set {
            guard newValue != .paused else { isPaused = true; return }
            if isPaused { resumeModeRaw = newValue.rawValue } else { mode = newValue }
        }
    }

    var order: NewCardOrder {
        get { NewCardOrder(rawValue: orderRaw) ?? .sequential }
        set { orderRaw = newValue.rawValue }
    }

    /// 停用（單字庫已刪除）的卡不算；連過來的卡也算
    var activeCards: [Card] { allCards.filter { !$0.isRetired } }

    /// 牌組頁、商店的小方塊文字：L1–L6、Ph、或自訂牌組的第一個字
    var tileLabel: String {
        if let level { return "L\(level)" }
        if category == .phrase { return "Ph" }
        if category == .pattern { return "St" }
        return String(name.prefix(1))
    }
}
