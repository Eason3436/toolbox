import HealthKit
import Foundation

/// 最近一段時間的健康摘要（用於 App 內回顯已同步的資料）。
struct HealthSummary: Sendable {
    var stepCount: Double?
    var sleepMinutes: Double?
    var avgHeartRate: Double?
    var avgRespiratoryRate: Double?
    var avgHRV: Double?
}

/// 單日趨勢資料點（用於 Charts）。
struct DailyTrend: Identifiable, Sendable {
    let date: Date
    let stepCount: Double?
    let avgHeartRate: Double?
    let sleepMinutes: Double?
    let avgHRV: Double?

    var id: Date { date }
}

/// 從 HealthKit 讀回摘要，讓使用者在 App 裡直接看到已同步的資料。
enum HealthKitReader {
    /// 最近 7 天（含今天）的摘要。
    static func summary(days: Int = 7) async -> HealthSummary {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        var summary = HealthSummary()
        summary.stepCount = try? await sum(
            .stepCount, unit: .count(), start: start, end: end
        )
        summary.avgHeartRate = try? await average(
            .heartRate, unit: .count().unitDivided(by: .minute()), start: start, end: end
        )
        summary.avgRespiratoryRate = try? await average(
            .respiratoryRate, unit: .count().unitDivided(by: .minute()), start: start, end: end
        )
        summary.avgHRV = try? await average(
            .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: end
        )
        summary.sleepMinutes = try? await sleepMinutes(from: start, to: end)
        return summary
    }

    // MARK: - 按天趨勢序列（用於 Charts）

    /// 最近 N 天每天的步數、心率、睡眠、HRV 趨勢資料。
    static func trendSeries(days: Int = 7) async -> [DailyTrend] {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now
        let dayStart = calendar.startOfDay(for: start)

        // 四個查詢互相獨立，用 async let 並行執行
        async let stepTask = dailyCollection(
            .stepCount, unit: .count(), start: dayStart, end: now, option: .cumulativeSum
        )
        async let hrTask = dailyCollection(
            .heartRate, unit: .count().unitDivided(by: .minute()), start: dayStart, end: now, option: .discreteAverage
        )
        async let hrvTask = dailyCollection(
            .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: dayStart, end: now, option: .discreteAverage
        )
        async let sleepTask = dailySleep(start: dayStart, end: now)

        let sleepMap = await sleepTask
        let stepMap: [Date: Double] = (try? await stepTask) ?? [:]
        let hrMap: [Date: Double] = (try? await hrTask) ?? [:]
        let hrvMap: [Date: Double] = (try? await hrvTask) ?? [:]

        var trends: [DailyTrend] = []
        for offset in 0..<days {
            let day = calendar.date(byAdding: .day, value: offset, to: dayStart) ?? dayStart
            trends.append(DailyTrend(
                date: day,
                stepCount: stepMap[day],
                avgHeartRate: hrMap[day],
                sleepMinutes: sleepMap[day],
                avgHRV: hrvMap[day]
            ))
        }
        return trends
    }

    /// 用 HKStatisticsCollectionQuery 按天分桶查詢。
    private static func dailyCollection(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
        start: Date, end: Date, option: HKStatisticsOptions
    ) async throws -> [Date: Double] {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: start)
        var result: [Date: Double] = [:]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let query = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(identifier),
                quantitySamplePredicate: predicate,
                options: option,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let value: Double?
                    if option == .cumulativeSum {
                        value = stats.sumQuantity()?.doubleValue(for: unit)
                    } else {
                        value = stats.averageQuantity()?.doubleValue(for: unit)
                    }
                    let day = calendar.startOfDay(for: stats.startDate)
                    if let value { result[day] = value }
                }
                continuation.resume()
            }
            HealthKitManager.healthStore.execute(query)
        }
        return result
    }

    /// 睡眠按天聚合（查詢原始樣本手動按天分桶）。
    private static func dailySleep(start: Date, end: Date) async -> [Date: Double] {
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        guard let samples = try? await query(HKCategoryType(.sleepAnalysis), predicate: predicate) else {
            return [:]
        }
        let sleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        var map: [Date: Double] = [:]
        for sample in samples.compactMap({ $0 as? HKCategorySample }) where sleepValues.contains(sample.value) {
            let day = calendar.startOfDay(for: sample.startDate)
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60
            map[day, default: 0] += minutes
        }
        return map
    }

    private static func sum(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date
    ) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let stats = try await statistics(
            for: HKQuantityType(identifier), predicate: predicate, options: .cumulativeSum
        )
        return stats.sumQuantity()?.doubleValue(for: unit)
    }

    private static func average(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date
    ) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let stats = try await statistics(
            for: HKQuantityType(identifier), predicate: predicate, options: .discreteAverage
        )
        return stats.averageQuantity()?.doubleValue(for: unit)
    }

    /// 睡眠總時長（分鐘）= asleepUnspecified / Core / Deep / REM 之和。
    private static func sleepMinutes(from start: Date, to end: Date) async throws -> Double {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let samples = try await query(HKCategoryType(.sleepAnalysis), predicate: predicate)
        let sleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        return samples
            .compactMap { $0 as? HKCategorySample }
            .filter { sleepValues.contains($0.value) }
            .reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) / 60 }
    }

    // MARK: - 底層查詢

    private static func statistics(
        for type: HKQuantityType, predicate: NSPredicate, options: HKStatisticsOptions
    ) async throws -> HKStatistics {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let statistics {
                    continuation.resume(returning: statistics)
                } else {
                    continuation.resume(throwing: HealthKitReaderError.noStatistics)
                }
            }
            HealthKitManager.healthStore.execute(query)
        }
    }

    private static func query(_ type: HKObjectType, predicate: NSPredicate) async throws -> [HKObject] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type as! HKSampleType, predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            HealthKitManager.healthStore.execute(query)
        }
    }

    enum HealthKitReaderError: LocalizedError {
        case noStatistics
        var errorDescription: String? { "沒有可用的統計資料" }
    }
}
