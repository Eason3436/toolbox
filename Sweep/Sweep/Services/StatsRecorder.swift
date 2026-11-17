import Foundation
import SwiftData

/// 把瀏覽與刪除記到 SwiftData
@MainActor
enum StatsRecorder {
    /// 第一次看到才算一次「查看」
    static func recordViewed(_ id: String, kind: StatsKind, context: ModelContext) {
        let descriptor = FetchDescriptor<ViewedAsset>(predicate: #Predicate { $0.assetID == id })
        if let count = try? context.fetchCount(descriptor), count > 0 { return }
        context.insert(ViewedAsset(assetID: id, category: kind))
        stats(for: kind, context: context).viewedCount += 1
        try? context.save()
    }

    static func recordDeleted(_ records: [(id: String, kind: StatsKind, bytes: Int64)], context: ModelContext) {
        guard !records.isEmpty else { return }
        for record in records {
            let id = record.id
            let descriptor = FetchDescriptor<ViewedAsset>(predicate: #Predicate { $0.assetID == id })
            let viewed: ViewedAsset
            if let existing = try? context.fetch(descriptor).first {
                viewed = existing
            } else {
                viewed = ViewedAsset(assetID: id, category: record.kind)
                context.insert(viewed)
                stats(for: record.kind, context: context).viewedCount += 1
            }
            viewed.wasDeleted = true
            viewed.fileSize = record.bytes
            let totals = stats(for: record.kind, context: context)
            totals.deletedCount += 1
            totals.freedBytes += record.bytes
        }
        try? context.save()
    }

    /// 看過的 ID（抽組時排除）
    static func viewedIDs(context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<ViewedAsset>()
        let all = (try? context.fetch(descriptor)) ?? []
        return Set(all.map(\.assetID))
    }

    /// 清掉瀏覽記錄，看過的照片回到隨機池。統計數字不動。
    static func resetViewed(context: ModelContext) {
        try? context.delete(model: ViewedAsset.self)
        try? context.save()
    }

    static func stats(for kind: StatsKind, context: ModelContext) -> CleanStats {
        let raw = kind.rawValue
        let descriptor = FetchDescriptor<CleanStats>(predicate: #Predicate { $0.category == raw })
        if let existing = try? context.fetch(descriptor).first { return existing }
        let created = CleanStats(category: kind)
        context.insert(created)
        return created
    }
}
