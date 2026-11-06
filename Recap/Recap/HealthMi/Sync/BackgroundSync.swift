import BackgroundTasks
import Foundation
import os

/// BGAppRefreshTask 後臺同步（模擬器不會觸發，需真機執行驗證）。
enum BackgroundSync {
    static let taskIdentifier = "com.eason3436.recap.healthsync"

    /// 當前後臺同步 Task 引用，用於 expirationHandler 取消。
    @MainActor private static var syncTask: Task<Void, Never>?

    @MainActor
    static func register(syncHandler: @escaping @MainActor () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            schedule()
            refreshTask.expirationHandler = {
                // 系統即將掛起程序，取消正在進行的同步
                Task { @MainActor in
                    syncTask?.cancel()
                }
                refreshTask.setTaskCompleted(success: false)
            }
            syncTask = Task { @MainActor in
                await syncHandler()
                refreshTask.setTaskCompleted(success: true)
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.backgroundSync.error("後臺同步排程失敗：\(error.localizedDescription)")
        }
    }
}
