import BackgroundTasks
import Foundation
import Observation
import UIKit
import UserNotifications

/// 全 App 共用的服務。
@MainActor
final class AppModel {
    static let shared = AppModel()

    let store = RecapStore.shared
    let settings = AppSettings.shared
    let queue: ProcessingQueue
    let recorder: RecordingController
    let router = Router()
    let quickRecap: QuickRecap

    private init() {
        queue = ProcessingQueue(store: store, settings: settings)
        recorder = RecordingController(store: store, settings: settings, queue: queue)
        quickRecap = QuickRecap(store: store, settings: settings, recorder: recorder)
        LiveActivityActions.stop = { [recorder] in await recorder.stop() }
        LiveActivityActions.pause = { [recorder] in recorder.pause() }
        LiveActivityActions.resume = { [recorder] in await recorder.resume() }
    }

    /// recap://quick?minutes=15（即時動態按鈕）
    func handle(_ url: URL) {
        guard url.scheme == "recap" else { return }
        if url.host == "quick" {
            let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "minutes" })?.value.flatMap(Int.init) ?? 15
            router.showQuickRecap = true
            Task { await quickRecap.run(minutes: minutes) }
        } else if recorder.mode == .lecture, recorder.isActive {
            router.tab = .lecture
        }
    }

    func didBecomeActive() {
        recorder.appDidBecomeActive()
        recorder.cleanUpStaleActivities()
        queue.kick(summaries: true)
        store.purgeAudio(olderThan: settings.audioRetentionDays)
        autoStartIfScheduled()
    }

    func didEnterBackground() {
        queue.enterBackground()
        if queue.hasWork { BackgroundProcessing.schedule() }
    }

    /// 在排程時段內打開 App → 自動開始錄音。
    func autoStartIfScheduled() {
        guard settings.autoStartInSchedule, !recorder.isActive,
              let active = settings.activeSchedule(),
              !recorder.wasManuallyStoppedInCurrentWindow() else { return }
        Task { try? await recorder.start(mode: active.rule.mode, source: .schedule) }
    }

    func schedulesChanged() {
        Task {
            if settings.scheduleNotifications { await Notifications.requestPermission() }
            await Notifications.reschedule(settings.schedules, enabled: settings.scheduleNotifications)
        }
    }
}

/// 畫面導覽。
@MainActor
@Observable
final class Router {
    enum Tab: Hashable { case today, lecture, history, settings }
    var tab: Tab = .today
    /// 顯示「最近 N 分鐘重點」
    var showQuickRecap = false
}

/// 背景整理：BGProcessingTask，接電源時才跑（轉文字＋摘要＋Recap）。
enum BackgroundProcessing {
    static let identifier = "com.eason3436.recap.process"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            handle(task)
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            appLog.info("背景任務排程失敗：\(error.localizedDescription)")
        }
    }

    private static func handle(_ task: BGTask) {
        nonisolated(unsafe) let task = task
        let work = Task { @MainActor in
            let queue = AppModel.shared.queue
            await queue.runToCompletion()
            if queue.hasWork { schedule() }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in
                AppModel.shared.queue.cancel()
                schedule()
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundProcessing.register()
        MainActor.assumeIsolated { _ = AppModel.shared }
        Notifications.registerCategories()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier
        let modeRaw = info["mode"] as? String
        await MainActor.run {
            let model = AppModel.shared
            switch category {
            case Notifications.scheduleCategory:
                let mode = modeRaw.flatMap(RecordingMode.init(rawValue:)) ?? .allDay
                Task { try? await model.recorder.start(mode: mode, source: .schedule) }
                model.router.tab = mode == .lecture ? .lecture : .today
            case Notifications.resumeCategory:
                Task { await model.recorder.resume() }
            default:
                break
            }
        }
    }
}
