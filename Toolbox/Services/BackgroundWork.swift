import ActivityKit
import Foundation
import BackgroundTasks
import UIKit

/// 用 iOS 26 起的 BGContinuedProcessingTask 讓處理在切到背景後繼續進行，
/// 系統會在動態島與鎖定畫面顯示進度（即時動態），也可以從那裡取消。
///
/// 裝在 LiveContainer 裡時系統不認得 Toolbox 的背景工作，改用 LiveContainer 的
/// 即時動態（LCLiveActivityAttributes）顯示進度，並向系統多要一點背景時間。
final class BackgroundWork: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var fraction: Double = 0
    private var subtitle: String
    private let title: String
    private var finished = false
    private var finishedSuccess = false
    private var expiration: (@Sendable () -> Void)?

    // LiveContainer 的即時動態
    private var usesLiveContainer = false
    private var lcActivity: Activity<LCLiveActivityAttributes>?
    private var lcLastPush = Date.distantPast
    private var lcLastFraction: Double = -1
    private var lcPending: Task<Void, Never>?
    private var lcBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lcStartedAt = Date()

    private init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    /// 要跟 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 一致。
    /// SideStore 重新簽名時可能改掉 bundle ID，所以這裡寫死，不讀 Bundle.main。
    private static let identifierPrefix = "com.eason3436.toolbox.process"

    /// 開始一個背景工作。系統不允許時仍會回傳物件，只是不會顯示進度（前景照常處理）。
    static func begin(title: String, subtitle: String) -> BackgroundWork {
        let work = BackgroundWork(title: title, subtitle: subtitle)
        if LCLiveActivityAttributes.isInsideLiveContainer {
            work.startLiveContainerActivity()
            return work
        }
        let identifier = identifierPrefix + "." + UUID().uuidString.prefix(8).lowercased()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            work.attach(continued)
        }
        guard registered else { return work }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // 系統忙碌或不支援時就只在前景處理。
        }
        return work
    }

    /// 系統要求停止（使用者從動態島按取消，或資源不足）時呼叫。
    func onExpiration(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        expiration = handler
        lock.unlock()
    }

    func update(fraction newFraction: Double) {
        lock.lock()
        fraction = Swift.min(Swift.max(newFraction, 0), 1)
        let task = self.task
        let value = fraction
        lock.unlock()
        task?.progress.completedUnitCount = Int64(value * 1000)
        if usesLiveContainer { pushLiveContainerState() }
    }

    func update(subtitle newSubtitle: String) {
        lock.lock()
        subtitle = newSubtitle
        let task = self.task
        lock.unlock()
        task?.updateTitle(title, subtitle: newSubtitle)
        if usesLiveContainer { pushLiveContainerState(force: true) }
    }

    func finish(success: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        finishedSuccess = success
        let task = self.task
        self.task = nil
        lock.unlock()
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.updateTitle(title, subtitle: success ? "完成" : "未完成")
            task.setTaskCompleted(success: success)
        }
        if usesLiveContainer { endLiveContainerActivity(success: success) }
    }

    private func attach(_ continued: BGContinuedProcessingTask) {
        lock.lock()
        if finished {
            let success = finishedSuccess
            lock.unlock()
            continued.setTaskCompleted(success: success)
            return
        }
        task = continued
        let value = fraction
        let currentSubtitle = subtitle
        lock.unlock()

        continued.progress.totalUnitCount = 1000
        continued.progress.completedUnitCount = Int64(value * 1000)
        continued.updateTitle(title, subtitle: currentSubtitle)
        continued.expirationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let handler = self.expiration
            self.task = nil
            self.finished = true
            self.lock.unlock()
            handler?()
            continued.setTaskCompleted(success: false)
        }
    }

    // MARK: - LiveContainer

    private func startLiveContainerActivity() {
        usesLiveContainer = true
        lcStartedAt = Date()
        Task { @MainActor in
            self.beginLiveContainerBackgroundTime()
            var activity: Activity<LCLiveActivityAttributes>? = nil
            if ActivityAuthorizationInfo().areActivitiesEnabled {
                let attributes = LCLiveActivityAttributes.forCurrentApp(
                    systemImage: "doc.badge.gearshape.fill",
                    tintHex: "#0A84FF"
                )
                let content = ActivityContent(state: self.liveContainerState(), staleDate: Date().addingTimeInterval(90))
                activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            }
            self.lock.lock()
            let alreadyFinished = self.finished
            let success = self.finishedSuccess
            self.lcActivity = activity
            self.lock.unlock()
            // 處理在即時動態開好之前就結束了
            if alreadyFinished { self.endLiveContainerActivity(success: success) }
        }
    }

    /// 切到背景後向系統多要一點時間；時間到了處理會暫停，回到 App 再繼續。
    @MainActor
    private func beginLiveContainerBackgroundTime() {
        let id = UIApplication.shared.beginBackgroundTask(withName: "Toolbox") { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let id = self.lcBackgroundTask
            self.lcBackgroundTask = .invalid
            self.lock.unlock()
            self.pushLiveContainerState(force: true, note: "回到 Toolbox 繼續處理")
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
        lock.lock()
        lcBackgroundTask = id
        lock.unlock()
    }

    private func liveContainerState(note: String? = nil, finishedSuccess: Bool? = nil) -> LCLiveActivityAttributes.ContentState {
        lock.lock()
        let value = fraction
        let text = subtitle
        lock.unlock()
        if let finishedSuccess {
            return LCLiveActivityAttributes.ContentState(
                title: title,
                subtitle: finishedSuccess ? "完成" : "未完成",
                systemImage: finishedSuccess ? "checkmark" : "xmark",
                progress: finishedSuccess ? 1 : value,
                tintHex: finishedSuccess ? "#34C759" : "#8E8E93",
                pausedElapsed: Date().timeIntervalSince(lcStartedAt),
                isFinished: true
            )
        }
        return LCLiveActivityAttributes.ContentState(
            title: title,
            subtitle: note ?? text,
            progress: value
        )
    }

    /// 最多每秒更新一次，進度變化不到 1% 就略過（系統對即時動態的更新次數有限制）。
    private func pushLiveContainerState(force: Bool = false, note: String? = nil) {
        lock.lock()
        guard let activity = lcActivity, !finished else { lock.unlock(); return }
        let value = fraction
        let tooSoon = Date().timeIntervalSince(lcLastPush) < 1
        let tooSmall = abs(value - lcLastFraction) < 0.01
        if !force && (tooSoon || tooSmall) { lock.unlock(); return }
        lcLastPush = Date()
        lcLastFraction = value
        lock.unlock()
        let content = ActivityContent(state: liveContainerState(note: note), staleDate: Date().addingTimeInterval(90))
        Task { await activity.update(content) }
    }

    private func endLiveContainerActivity(success: Bool) {
        lock.lock()
        let activity = lcActivity
        lcActivity = nil
        let backgroundTask = lcBackgroundTask
        lcBackgroundTask = .invalid
        lock.unlock()
        if let activity {
            let content = ActivityContent(state: liveContainerState(finishedSuccess: success), staleDate: nil)
            // 完成後在鎖定畫面留 5 分鐘
            Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(5 * 60))) }
        }
        if backgroundTask != .invalid {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
    }
}
