import os

/// 統一日誌入口，按 category 分類，便於在 Console.app 中過濾。
enum AppLog {
    static let subsystem = "com.healthmi.HealthMi"

    static let backgroundSync = Logger(subsystem: subsystem, category: "BackgroundSync")
    static let apiClient = Logger(subsystem: subsystem, category: "MiAPIClient")
    static let syncStateStore = Logger(subsystem: subsystem, category: "SyncStateStore")
    static let stressStore = Logger(subsystem: subsystem, category: "StressStore")
    static let syncLogStore = Logger(subsystem: subsystem, category: "SyncLogStore")
}
