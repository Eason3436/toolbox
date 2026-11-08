import Foundation
import SwiftData

/// 分析狀態。資料庫裡存字串（`statusRaw`），方便在 #Predicate 中篩選。
enum AnalysisStatus: String, Codable, Sendable {
    case pending
    case done
    case failed
}

/// 一張截圖。只存 `PHAsset.localIdentifier` 與分析結果，不複製原圖。
@Model
final class ScreenshotItem {
    @Attribute(.unique) var assetID: String
    var createdAt: Date
    var statusRaw: String
    var title: String?
    var summary: String?
    var category: String?
    var ocrText: String?
    var keywords: [String]
    /// 日期、地點、網址、電話、價格（`ScreenshotEntities` 的 JSON）
    var entitiesJSON: Data?
    var isPinned: Bool
    var isArchived: Bool
    /// 從分享或捷徑送進來、不一定是系統截圖的圖片；全量同步時不會因為「不是截圖」被移除。
    var isManual: Bool
    var failureMessage: String?
    var analyzedAt: Date?
    @Relationship(deleteRule: .nullify, inverse: \ScreenshotCollection.items)
    var collections: [ScreenshotCollection]

    init(assetID: String, createdAt: Date, isManual: Bool = false) {
        self.assetID = assetID
        self.createdAt = createdAt
        self.statusRaw = AnalysisStatus.pending.rawValue
        self.keywords = []
        self.isPinned = false
        self.isArchived = false
        self.isManual = isManual
        self.collections = []
    }

    var status: AnalysisStatus {
        get { AnalysisStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var entities: ScreenshotEntities {
        get {
            guard let entitiesJSON else { return ScreenshotEntities() }
            return (try? JSONDecoder().decode(ScreenshotEntities.self, from: entitiesJSON)) ?? ScreenshotEntities()
        }
        set { entitiesJSON = try? JSONEncoder().encode(newValue) }
    }

    var categoryValue: ScreenshotCategory? {
        category.flatMap(ScreenshotCategory.init(rawValue:))
    }

    /// 給搜尋用的不可變快照（可跨執行緒傳遞）。
    var searchDocument: SearchDocument {
        SearchDocument(
            id: assetID,
            title: title ?? "",
            summary: summary ?? "",
            ocrText: ocrText ?? "",
            keywords: keywords,
            category: category,
            createdAt: createdAt
        )
    }
}

/// 收藏集。（規格中叫 Collection，但會和 Swift 內建的 Collection 協定撞名，所以改名。）
@Model
final class ScreenshotCollection {
    var name: String
    /// SF Symbol 名稱
    var symbol: String
    /// 設定後，分析結果為這個分類的截圖會自動加入。
    var autoRuleCategory: String?
    var createdAt: Date
    var items: [ScreenshotItem]

    init(name: String, symbol: String, autoRuleCategory: String? = nil) {
        self.name = name
        self.symbol = symbol
        self.autoRuleCategory = autoRuleCategory
        self.createdAt = .now
        self.items = []
    }
}
