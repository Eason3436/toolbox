import Foundation
import SwiftData
import os

/// 壓力記錄（來自小米雲端 stress key，無 HealthKit 對應型別，存 SwiftData 供 App 內展示）。
@Model
final class StressRecord {
    @Attribute(.unique) var externalID: String
    var timestamp: Date
    var stressScore: Int

    init(externalID: String, timestamp: Date, stressScore: Int) {
        self.externalID = externalID
        self.timestamp = timestamp
        self.stressScore = stressScore
    }
}

/// 壓力資料存取（MainActor，SwiftData 上下文非 Sendable）。
@MainActor
enum StressStore {

    /// 批次寫入壓力記錄，按 externalID 去重，返回新增條數。
    @discardableResult
    static func save(samples: [MiStressSample], in context: ModelContext) -> Int {
        guard !samples.isEmpty else { return 0 }
        let ids = Set(samples.map(\.id))
        let existing = fetchExistingIDs(ids: ids, in: context)
        var added = 0
        for sample in samples where !existing.contains(sample.id) {
            context.insert(StressRecord(
                externalID: sample.id,
                timestamp: sample.timestamp,
                stressScore: sample.stressScore
            ))
            added += 1
        }
        if added > 0 {
            do {
                try context.save()
            } catch {
                AppLog.stressStore.error("儲存壓力記錄失敗：\(error.localizedDescription)")
            }
        }
        return added
    }

    /// 刪除指定時間範圍內的壓力記錄（重新回填時先清理）。
    static func deleteRange(start: Date, end: Date, in context: ModelContext) {
        let descriptor = FetchDescriptor<StressRecord>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end }
        )
        if let records = try? context.fetch(descriptor) {
            for record in records {
                context.delete(record)
            }
            try? context.save()
        }
    }

    /// 清除所有壓力記錄（退出登入時呼叫）。
    static func clearAll(in context: ModelContext) {
        let descriptor = FetchDescriptor<StressRecord>()
        if let records = try? context.fetch(descriptor) {
            for record in records {
                context.delete(record)
            }
            try? context.save()
        }
    }

    /// 查詢最近 N 天的壓力記錄（按時間排序）。
    static func recent(days: Int, in context: ModelContext) -> [StressRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<StressRecord>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchExistingIDs(ids: Set<String>, in context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<StressRecord>(
            predicate: #Predicate { ids.contains($0.externalID) }
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return Set(records.map(\.externalID))
    }
}
