import HealthKit
import Foundation

/// 冪等寫入器，復刻 `healthloom.app` 的 `HealthKitWriter` 模式：
/// - 每個樣本帶 `HKMetadataKeyExternalUUID`；
/// - 寫入前按「型別 + 時間段」一次查詢已有的 externalID，記憶體裡 diff 後只儲存新增批次；
/// - 更新 = 按 externalID 刪除 + 重插（HK 樣本不可變）。
actor HealthWriter {
    private let store: HKHealthStore

    init(store: HKHealthStore = HealthKitManager.healthStore) {
        self.store = store
    }

    /// 該型別在 `[start, end]` 內已寫入的 externalID 集合。
    /// 使用軟邊界（不限制 strictStart/strictEnd），確保跨越視窗起點的睡眠會話不會被漏掉。
    func existingExternalIDs(ofType type: HKSampleType, start: Date, end: Date) async throws -> Set<String> {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID),
        ])
        var ids = Set<String>()
        var anchor: Date? = nil
        while true {
            let samples = try await queryPage(type: type, predicate: predicate, anchor: anchor)
            guard !samples.isEmpty else { break }
            for sample in samples {
                if let uuid = sample.metadata?[HKMetadataKeyExternalUUID] as? String {
                    ids.insert(uuid)
                }
                if let last = samples.last, last.startDate > (anchor ?? .distantPast) {
                    anchor = last.startDate
                }
            }
            if samples.count < Self.pageSize { break }
        }
        return ids
    }

    /// 一次性批次儲存（空批次直接跳過）。
    func save(_ batch: [HKObject]) async throws {
        guard !batch.isEmpty else { return }
        try await store.save(batch)
    }

    /// 用 `HKWorkoutBuilder` 構建並儲存一條運動記錄。
    /// 保留 externalUUID metadata（builder 支援 addMetadata），繼續用於去重。
    /// 若草稿包含心率資料，建立關聯心率樣本並掛載到運動記錄上。
    func saveWorkout(_ draft: TypeMapper.WorkoutDraft) async throws -> HKWorkout {
        let config = HKWorkoutConfiguration()
        config.activityType = draft.activityType
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        do {
            try await builder.beginCollection(at: draft.start)
            try await builder.addMetadata([HKMetadataKeyExternalUUID: draft.externalUUID])
            try await builder.endCollection(at: draft.end)
            guard let workout = try await builder.finishWorkout() else {
                throw HealthWriterError.workoutBuildFailed
            }

            // 關聯心率樣本（平均/最大），用 externalUUID 字首確保去重
            var hrSamples: [HKQuantitySample] = []
            let hrType = HKQuantityType(.heartRate)
            let hrUnit = HKUnit.count().unitDivided(by: .minute())
            if let avg = draft.avgHeartRateBpm, avg > 0 {
                hrSamples.append(HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: hrUnit, doubleValue: Double(avg)),
                    start: draft.start, end: draft.end,
                    metadata: [HKMetadataKeyExternalUUID: "\(draft.externalUUID)_avg_hr"]
                ))
            }
            if let max = draft.maxHeartRateBpm, max > 0 {
                hrSamples.append(HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: hrUnit, doubleValue: Double(max)),
                    start: draft.start, end: draft.end,
                    metadata: [HKMetadataKeyExternalUUID: "\(draft.externalUUID)_max_hr"]
                ))
            }
            if !hrSamples.isEmpty {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    store.add(hrSamples, to: workout) { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if !success {
                            continuation.resume(throwing: HealthWriterError.workoutBuildFailed)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }

            return workout
        } catch {
            builder.discardWorkout()
            throw error
        }
    }

    enum HealthWriterError: LocalizedError {
        case workoutBuildFailed
        var errorDescription: String? { "運動記錄構建失敗" }
    }

    /// 按 externalID 刪除指定型別的物件，返回刪除數量。
    @discardableResult
    func delete(ofType type: HKObjectType, externalIDs: Set<String>) async throws -> Int {
        guard !externalIDs.isEmpty else { return 0 }
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            allowedValues: Array(externalIDs)
        )
        return try await withCheckedThrowingContinuation { continuation in
            store.deleteObjects(of: type, predicate: predicate) { _, count, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: count)
                }
            }
        }
    }

    // MARK: - 分頁查詢

    private static let pageSize = 1000

    private func queryPage(
        type: HKSampleType, predicate: NSPredicate, anchor: Date?
    ) async throws -> [HKSample] {
        var combined = predicate
        if let anchor {
            combined = NSCompoundPredicate(andPredicateWithSubpredicates: [
                predicate,
                HKQuery.predicateForSamples(withStart: anchor, end: nil),
            ])
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: combined,
                limit: Self.pageSize, sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }
}
