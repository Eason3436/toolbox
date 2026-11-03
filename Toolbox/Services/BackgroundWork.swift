import Foundation
import BackgroundTasks

/// 用 iOS 26 起的 BGContinuedProcessingTask 讓處理在切到背景後繼續進行，
/// 系統會在動態島與鎖定畫面顯示進度（即時動態），也可以從那裡取消。
final class BackgroundWork: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var fraction: Double = 0
    private var subtitle: String
    private let title: String
    private var finished = false
    private var finishedSuccess = false
    private var expiration: (@Sendable () -> Void)?

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
    }

    func update(subtitle newSubtitle: String) {
        lock.lock()
        subtitle = newSubtitle
        let task = self.task
        lock.unlock()
        task?.updateTitle(title, subtitle: newSubtitle)
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
}
