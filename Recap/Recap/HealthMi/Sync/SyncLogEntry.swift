import Foundation
import SwiftData
import os

/// 單次型別同步的歷史記錄。
@Model
final class SyncLogEntry {
    var timestamp: Date
    var typeRawValue: String
    var fetched: Int
    var added: Int
    var success: Bool
    var errorMessage: String?

    init(timestamp: Date, typeRawValue: String, fetched: Int, added: Int, success: Bool, errorMessage: String? = nil) {
        self.timestamp = timestamp
        self.typeRawValue = typeRawValue
        self.fetched = fetched
        self.added = added
        self.success = success
        self.errorMessage = errorMessage
    }

    var displayName: String {
        SyncDataType(rawValue: typeRawValue)?.displayName ?? typeRawValue
    }
}

/// 同步日誌存取（MainActor，SwiftData 上下文非 Sendable）。
@MainActor
enum SyncLogStore {

    static func append(
        type: SyncDataType, fetched: Int, added: Int,
        success: Bool, errorMessage: String? = nil, in context: ModelContext
    ) {
        let entry = SyncLogEntry(
            timestamp: Date(),
            typeRawValue: type.rawValue,
            fetched: fetched, added: added,
            success: success, errorMessage: errorMessage
        )
        context.insert(entry)
        do {
            try context.save()
        } catch {
            AppLog.syncLogStore.error("儲存同步日誌失敗：\(error.localizedDescription)")
        }
        pruneOldEntries(in: context)
    }

    /// 保留最近 200 條日誌，避免無限增長。
    private static func pruneOldEntries(in context: ModelContext) {
        let descriptor = FetchDescriptor<SyncLogEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        guard let all = try? context.fetch(descriptor) else { return }
        let limit = 200
        if all.count > limit {
            for entry in all.dropFirst(limit) {
                context.delete(entry)
            }
            try? context.save()
        }
    }

    static func clearAll(in context: ModelContext) {
        let descriptor = FetchDescriptor<SyncLogEntry>()
        if let entries = try? context.fetch(descriptor) {
            for entry in entries {
                context.delete(entry)
            }
            try? context.save()
        }
    }
}
