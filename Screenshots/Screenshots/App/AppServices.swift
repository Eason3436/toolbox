import BackgroundTasks
import SwiftData
import SwiftUI

/// 全 App 共用的服務（App、App Intents、背景任務都從這裡取）。
@MainActor
final class AppServices {
    static let shared = AppServices()

    let container: ModelContainer
    let queue: AnalysisQueue
    let queueStatus = QueueStatus()
    let library: PhotoSyncService
    let router = AppRouter()
    /// 資料庫開不起來時的錯誤訊息（改用暫存資料庫）
    let storageError: String?

    private init() {
        let schema = Schema([ScreenshotItem.self, ScreenshotCollection.self])
        let storeURL = AppGroup.directory("Database").appending(path: "Screenshots.store")
        var storageError: String?
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
        } catch {
            appLog.error("資料庫開啟失敗：\(error.localizedDescription)")
            storageError = "資料庫開啟失敗，這次先用暫存資料庫（關閉 App 後資料不會保留）。\n\(error.localizedDescription)"
            // 暫存資料庫一定建得起來
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        }
        self.container = container
        self.storageError = storageError
        let queue = AnalysisQueue(modelContainer: container)
        self.queue = queue
        self.library = PhotoSyncService(context: container.mainContext, queue: queue)
        let status = queueStatus
        Task { await queue.attach(status: status) }
    }

    // MARK: - 生命週期

    /// 回到前景：增量同步、處理分享收件匣、繼續分析。
    func didBecomeActive() {
        library.refreshAccess()
        library.startObserving()
        library.sync()
        Task {
            await queue.setAppActive(true)
            await library.processInbox()
            await queue.enqueueAllPending()
        }
    }

    func didEnterBackground() {
        Task { await queue.setAppActive(false) }
        BackgroundAnalysis.schedule()
    }
}

/// 背景補分析：BGProcessingTask，需接電源。
enum BackgroundAnalysis {
    static let identifier = "com.eason3436.screenshots.analyze"

    /// 必須在 App 啟動完成前呼叫。
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            handle(task)
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            appLog.info("背景任務排程失敗：\(error.localizedDescription)")
        }
    }

    private static func handle(_ task: BGTask) {
        nonisolated(unsafe) let task = task
        let work = Task { @MainActor in
            let queue = AppServices.shared.queue
            await queue.runInBackground()
            let remaining = await queue.hasWork
            if remaining { schedule() }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in
                await AppServices.shared.queue.stopBackgroundRun()
                schedule()
            }
        }
    }
}

/// 分頁與導覽狀態（Spotlight、App Intents 會用到）。
@MainActor
@Observable
final class AppRouter {
    enum TabID: Hashable {
        case home, collections, ask, settings
    }

    var tab: TabID = .home
    var homePath = NavigationPath()
    var searchText = ""
    /// App Intent「問截圖」帶進來的問題
    var pendingQuestion: String?

    func openScreenshot(_ assetID: String) {
        tab = .home
        homePath.append(ScreenshotRoute(assetID: assetID))
    }

    func search(_ text: String) {
        tab = .home
        homePath = NavigationPath()
        searchText = text
    }
}

struct ScreenshotRoute: Hashable {
    let assetID: String
}
