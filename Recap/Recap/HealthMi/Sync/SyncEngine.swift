import Foundation
import HealthKit

/// 單次同步的結果摘要。
struct SyncOutcome: Sendable {
    let type: SyncDataType
    let fetched: Int
    let added: Int
    let highWater: Date
}

/// 同步引擎：取數 → 解析 → 對映 → 冪等寫入。
///
/// 寫法與已驗證的 Python 工具保持一致：每次按型別從雲端拉取時間區間資料，
/// 用 `HealthWriter` 按 externalID 去重後批次寫入 HealthKit。
actor SyncEngine {
    private let client: MiAPIClient
    private let writer: HealthWriter
    private var userId: String?

    /// 增量同步時與上次遊標的重疊天數（彌補遲到資料）。
    private let overlapDays = 1

    /// sleep 資料快取：sleep、respiratoryRate、hrv 三個型別共享同一份睡眠原始資料，
    /// 避免同一次同步中把 sleep key 下載三遍。按 (startTime, endTime) 命中快取。
    private var sleepCache: (startTime: Int, endTime: Int, items: [MiItem])?

    init(client: MiAPIClient = MiAPIClient(), writer: HealthWriter = HealthWriter()) {
        self.client = client
        self.writer = writer
    }

    /// 清除內部快取，在一次同步會話開始前呼叫。
    func clearCache() {
        sleepCache = nil
    }

    /// 獲取睡眠原始資料，帶快取（相同時間視窗只下載一次）。
    private func fetchSleepData(startTime: Int, endTime: Int) async throws -> [MiItem] {
        if let cache = sleepCache, cache.startTime == startTime, cache.endTime == endTime {
            return cache.items
        }
        let items = try await client.fetchData(key: "sleep", startTime: startTime, endTime: endTime)
        sleepCache = (startTime, endTime, items)
        return items
    }

    /// 登入並校驗憑據。
    func connect(userId: String, passToken: String) async throws {
        try await client.connect(userId: userId, passToken: passToken)
        self.userId = userId
    }

    /// 同步一類資料。
    /// - Parameters:
    ///   - highWater: 上次遊標；`nil` 表示首次同步
    ///   - backfillDays: 回填天數（僅在無遊標或 `forceBackfill` 時生效）
    ///   - forceBackfill: 為 true 時忽略遊標，按 `backfillDays` 重新拉取歷史
    func sync(
        type: SyncDataType, highWater: Date?, backfillDays: Int, forceBackfill: Bool = false
    ) async throws -> SyncOutcome {
        let now = Date()
        let start: Date
        if forceBackfill {
            // 重新回填：忽略遊標，按所選天數重拉歷史
            start = Calendar.current.date(byAdding: .day, value: -backfillDays, to: now) ?? now
        } else if let highWater {
            // 增量：從上次遊標往前重疊一天，避免遲到資料被漏掉
            start = Calendar.current.date(byAdding: .day, value: -overlapDays, to: highWater) ?? highWater
        } else {
            // 首次同步：按所選天數回填
            start = Calendar.current.date(byAdding: .day, value: -backfillDays, to: now) ?? now
        }
        let startTime = MiAPIClient.dayStartEpoch(of: start)
        let endTime = MiAPIClient.dayEndEpoch(of: now)

        // 運動記錄用 HKWorkoutBuilder 單獨寫入（不走通用分組儲存）
        if type == .workouts {
            return try await syncWorkouts(
                startTime: startTime, endTime: endTime, start: start, end: now,
                forceBackfill: forceBackfill
            )
        }

        let groups = try await fetchAndMap(type: type, startTime: startTime, endTime: endTime)

        var added = 0
        var fetched = 0
        for group in groups {
            let existing = try await writer.existingExternalIDs(
                ofType: group.sampleType, start: start, end: now
            )
            if forceBackfill {
                // 重新回填 = 重寫：刪除範圍內**我們已寫入的所有樣本**（外部 ID 匹配），再插入最新資料。
                // 刪除全部而非僅交集，是為了清理舊版寫入的已廢棄樣本（如舊的整晚 asleep 聚合樣本）。
                // 分塊刪除，避免單個謂詞過長（大量樣本時）。
                if !existing.isEmpty {
                    let chunkSize = 500
                    let all = Array(existing)
                    for index in stride(from: 0, to: all.count, by: chunkSize) {
                        let end = min(index + chunkSize, all.count)
                        try await writer.delete(ofType: group.sampleType, externalIDs: Set(all[index..<end]))
                    }
                }
                try await writer.save(group.objects)
                added += group.objects.count
            } else {
                let fresh = group.objects.filter { object in
                    guard let uuid = object.metadata?[HKMetadataKeyExternalUUID] as? String else {
                        return true
                    }
                    return !existing.contains(uuid)
                }
                try await writer.save(fresh)
                added += fresh.count
            }
            fetched += group.objects.count
        }

        return SyncOutcome(type: type, fetched: fetched, added: added, highWater: now)
    }

    /// 壓力資料同步：從雲端拉取 stress key，返回解析後的壓力樣本。
    /// 壓力資料無 HealthKit 對應型別，由 HMAppModel 寫入 SwiftData。
    /// - Returns: (壓力樣本列表, 同步結果摘要)
    func syncStress(
        highWater: Date?, backfillDays: Int, forceBackfill: Bool = false
    ) async throws -> (samples: [MiStressSample], outcome: SyncOutcome) {
        let (start, now, startTime, endTime) = syncWindow(
            highWater: highWater, backfillDays: backfillDays, forceBackfill: forceBackfill
        )
        let items = try await client.fetchData(key: "stress", startTime: startTime, endTime: endTime)
        let samples = MiParser.stressSamples(items)
        return (samples, SyncOutcome(type: .stress, fetched: samples.count, added: 0, highWater: now))
    }

    // MARK: - 視窗計算

    func syncWindow(
        highWater: Date?, backfillDays: Int, forceBackfill: Bool
    ) -> (start: Date, end: Date, startTime: Int, endTime: Int) {
        let now = Date()
        let start: Date
        if forceBackfill {
            start = Calendar.current.date(byAdding: .day, value: -backfillDays, to: now) ?? now
        } else if let highWater {
            start = Calendar.current.date(byAdding: .day, value: -overlapDays, to: highWater) ?? highWater
        } else {
            start = Calendar.current.date(byAdding: .day, value: -backfillDays, to: now) ?? now
        }
        return (start, now, MiAPIClient.dayStartEpoch(of: start), MiAPIClient.dayEndEpoch(of: now))
    }

    // MARK: - 取數與對映

    private struct HKGroup {
        let sampleType: HKSampleType
        let objects: [HKObject]
    }

    private func fetchAndMap(type: SyncDataType, startTime: Int, endTime: Int) async throws -> [HKGroup] {
        switch type {
        case .dailyActivity:
            let steps = try await client.fetchData(key: "steps", startTime: startTime, endTime: endTime)
            let calories = try await client.fetchData(key: "calories", startTime: startTime, endTime: endTime)
            let samples = MiParser.dailyActivity(stepsItems: steps, calorieItems: calories)
                .flatMap(TypeMapper.dailyActivitySamples)
            return groupBySampleType(samples)

        case .heartRate:
            let hr = try await client.fetchData(key: "heart_rate", startTime: startTime, endTime: endTime)
            let resting = try await client.fetchData(key: "resting_heart_rate", startTime: startTime, endTime: endTime)
            let samples = MiParser.heartRateSamples(hr, restingItems: resting)
                .compactMap(TypeMapper.heartRateSample)
            return groupBySampleType(samples)

        case .sleep:
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            let samples = MiParser.sleepSessions(items).flatMap(TypeMapper.sleepSamples)
            return groupBySampleType(samples)

        case .spo2:
            let items = try await client.fetchData(key: "spo2", startTime: startTime, endTime: endTime)
            let samples = MiParser.spo2Samples(items).compactMap(TypeMapper.spo2Sample)
            return groupBySampleType(samples)

        case .respiratoryRate:
            // 呼吸頻率資料來自睡眠記錄的 avg_breath，按睡眠時段各寫一條樣本
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            let samples = MiParser.respiratoryRateSamples(items)
                .compactMap(TypeMapper.respiratoryRateSample)
            return groupBySampleType(samples)

        case .hrv:
            // HRV 資料來自睡眠記錄的 avg_hrv / hrv_median，按睡眠時段各寫一條樣本
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            let samples = MiParser.hrvSamples(items).compactMap(TypeMapper.hrvSample)
            return groupBySampleType(samples)

        case .bodyMeasurements:
            let items = try await client.fetchData(key: "weight", startTime: startTime, endTime: endTime)
            let samples = MiParser.bodyMeasurements(items).flatMap(TypeMapper.bodyMeasurementSamples)
            return groupBySampleType(samples)

        case .stress:
            // 壓力資料不走 HealthKit，由 syncStress 方法處理
            return []

        case .workouts:
            // 不會走到這裡：sync() 已將運動路由到 syncWorkouts（HKWorkoutBuilder 專用）
            return []
        }
    }

    /// 運動記錄：取數 → 生成草稿 → 用 HKWorkoutBuilder 逐條寫入（按 externalUUID 去重）。
    private func syncWorkouts(
        startTime: Int, endTime: Int, start: Date, end: Date, forceBackfill: Bool
    ) async throws -> SyncOutcome {
        let items = try await client.fetchSportRecords(startTime: startTime, endTime: endTime)
        let drafts = MiParser.workouts(items).compactMap(TypeMapper.workoutDraft)
        let workoutType = HKObjectType.workoutType() as HKSampleType
        let existing = try await writer.existingExternalIDs(ofType: workoutType, start: start, end: end)

        var added = 0
        for draft in drafts {
            if forceBackfill {
                if existing.contains(draft.externalUUID) {
                    try await writer.delete(ofType: workoutType, externalIDs: [draft.externalUUID])
                    // 同時刪除關聯心率樣本（avg_hr / max_hr）
                    let hrType = HKQuantityType(.heartRate) as HKObjectType
                    let hrIDs: Set<String> = [
                        "\(draft.externalUUID)_avg_hr",
                        "\(draft.externalUUID)_max_hr",
                    ]
                    try await writer.delete(ofType: hrType, externalIDs: hrIDs)
                }
                _ = try await writer.saveWorkout(draft)
                added += 1
            } else if !existing.contains(draft.externalUUID) {
                _ = try await writer.saveWorkout(draft)
                added += 1
            }
        }
        return SyncOutcome(type: .workouts, fetched: drafts.count, added: added, highWater: Date())
    }

    /// 按 HealthKit 樣本型別分組（同一個同步批次內的不同 HK 型別需要分別去重）。
    private func groupBySampleType(_ samples: [HKSample]) -> [HKGroup] {
        Dictionary(grouping: samples, by: { $0.sampleType })
            .map { HKGroup(sampleType: $0.key, objects: $0.value) }
    }
}
