import Foundation
import SwiftData
import os

/// 可同步的資料型別。stress 無 HealthKit 對應型別，存 App 內 SwiftData 展示。
/// abnormal_heart_beat 暫不納入。
enum SyncDataType: String, CaseIterable, Identifiable, Sendable {
    case dailyActivity = "daily_activity"
    case heartRate = "heart_rate"
    case sleep = "sleep"
    case spo2 = "spo2"
    case respiratoryRate = "respiratory_rate"
    case hrv = "hrv"
    case bodyMeasurements = "body_measurements"
    case workouts = "workouts"
    case stress = "stress"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dailyActivity: return "日常活動"
        case .heartRate: return "心率"
        case .sleep: return "睡眠"
        case .spo2: return "血氧"
        case .respiratoryRate: return "呼吸頻率"
        case .hrv: return "心率變異性"
        case .bodyMeasurements: return "體重/體脂"
        case .workouts: return "運動記錄"
        case .stress: return "壓力"
        }
    }
}

/// 每類資料的同步遊標（high-water mark）。
@Model
final class SyncState {
    @Attribute(.unique) var typeRawValue: String
    /// 已同步到的最晚時間，用於增量拉取。
    var lastSyncedEnd: Date?
    var lastSyncAt: Date?
    var lastAddedCount: Int

    init(typeRawValue: String, lastSyncedEnd: Date? = nil, lastSyncAt: Date? = nil, lastAddedCount: Int = 0) {
        self.typeRawValue = typeRawValue
        self.lastSyncedEnd = lastSyncedEnd
        self.lastSyncAt = lastSyncAt
        self.lastAddedCount = lastAddedCount
    }
}

/// SwiftData 存取同步遊標（必須在 MainActor 上使用，SwiftData 上下文非 Sendable）。
@MainActor
enum SyncStateStore {

    static func state(for type: SyncDataType, in context: ModelContext) -> SyncState? {
        let raw = type.rawValue
        let descriptor = FetchDescriptor<SyncState>(
            predicate: #Predicate { $0.typeRawValue == raw }
        )
        return (try? context.fetch(descriptor))?.first
    }

    static func ensureState(for type: SyncDataType, in context: ModelContext) -> SyncState {
        if let existing = state(for: type, in: context) { return existing }
        let created = SyncState(typeRawValue: type.rawValue)
        context.insert(created)
        return created
    }

    static func record(
        type: SyncDataType, highWater: Date?, added: Int, in context: ModelContext
    ) {
        let state = ensureState(for: type, in: context)
        state.lastSyncedEnd = highWater
        state.lastSyncAt = Date()
        state.lastAddedCount = added
        do {
            try context.save()
        } catch {
            AppLog.syncStateStore.error("儲存同步遊標失敗 (\(type.rawValue))：\(error.localizedDescription)")
        }
    }

    /// 清除所有同步遊標（退出登入或切換賬號時呼叫，防止新賬號繼承舊進度）。
    static func clearAll(in context: ModelContext) {
        let descriptor = FetchDescriptor<SyncState>()
        do {
            let all = try context.fetch(descriptor)
            for state in all {
                context.delete(state)
            }
            try context.save()
        } catch {
            AppLog.syncStateStore.error("清除同步遊標失敗：\(error.localizedDescription)")
        }
    }
}
