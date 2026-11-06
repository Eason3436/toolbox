import AppIntents
import Foundation

/// "同步健康資料" App Intent：開啟 App 並觸發一次同步。
struct SyncHealthDataIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "同步健康資料"
    nonisolated static let description = IntentDescription("從小米雲端拉取最新健康資料，寫入 Apple 健康")
    nonisolated static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        SyncIntentTrigger.shouldSync = true
        return .result()
    }
}

/// App Intent 觸發標記，DashboardView 啟動時檢查。
enum SyncIntentTrigger {
    nonisolated(unsafe) static var shouldSync = false
}
