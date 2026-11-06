import HealthKit
import Foundation

/// HealthKit 授權與型別清單。
enum HealthKitManager {
    static let healthStore = HKHealthStore()

    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// 需要寫入（並讀取用於去重）的健康資料型別。
    static let typesToShare: Set<HKSampleType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.oxygenSaturation),
        HKQuantityType(.respiratoryRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.bodyMass),
        HKQuantityType(.bodyMassIndex),
        HKQuantityType(.leanBodyMass),
        HKQuantityType(.basalEnergyBurned),
        HKQuantityType(.bodyFatPercentage),
        HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType(),
    ]

    static let typesToRead: Set<HKObjectType> = typesToShare

    /// 請求讀寫授權（系統會展示授權彈窗）。
    static func requestAuthorization() async throws {
        try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead)
    }
}
