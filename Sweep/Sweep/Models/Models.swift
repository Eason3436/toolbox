import Foundation
import SwiftData

/// 看過的照片／影片。只存 ID，不存圖。
@Model
final class ViewedAsset {
    /// PHAsset.localIdentifier
    @Attribute(.unique) var assetID: String
    /// StatsKind 的 rawValue：photo / screenshot / video
    var category: String
    var viewedAt: Date
    /// 已經從相簿刪掉（`isDeleted` 是 SwiftData 自己的屬性，所以換個名字）
    var wasDeleted: Bool
    var fileSize: Int64

    init(assetID: String, category: StatsKind, viewedAt: Date = .now) {
        self.assetID = assetID
        self.category = category.rawValue
        self.viewedAt = viewedAt
        self.wasDeleted = false
        self.fileSize = 0
    }
}

/// 三類（照片、截圖、影片）各一筆的累計數字
@Model
final class CleanStats {
    @Attribute(.unique) var category: String
    var viewedCount: Int
    var deletedCount: Int
    var freedBytes: Int64

    init(category: StatsKind) {
        self.category = category.rawValue
        self.viewedCount = 0
        self.deletedCount = 0
        self.freedBytes = 0
    }

    var kind: StatsKind { StatsKind(rawValue: category) ?? .photo }
}
