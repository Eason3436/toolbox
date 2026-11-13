import Foundation
import ActivityKit

/// 在 LiveContainer 裡執行時，用 LiveContainer 內建的通用即時動態（LCLiveActivityAttributes）顯示處理進度。
///
/// 為什麼需要：工具箱在 LiveContainer 裡跑的時候，系統把即時動態當成 LiveContainer 的，
/// 只有 LiveContainer 自己的 widget（LCLiveActivityWidget）畫得出來，所以要用這個共用格式。
/// 系統的 BGContinuedProcessingTask 仍然照開，它負責讓處理在背景繼續；這裡只負責顯示。
@available(iOS 16.2, *)
final class LCLiveProgress: @unchecked Sendable {
    private let activity: Activity<LCLiveActivityAttributes>
    private let lock = NSLock()
    private var state: LCLiveActivityAttributes.ContentState
    private var lastSent = Date.distantPast
    private var ended = false

    /// 工具箱強調色（深色版，動態島和鎖定畫面背景偏暗）。
    private static let tintHex = "#9DB4D3"
    /// 系統限制即時動態的更新頻率，太密集會被節流，所以最多每秒送一次。
    private static let minimumInterval: TimeInterval = 1

    private init(activity: Activity<LCLiveActivityAttributes>, state: LCLiveActivityAttributes.ContentState) {
        self.activity = activity
        self.state = state
    }

    /// 不在 LiveContainer 裡、或使用者關掉即時動態時回傳 nil。
    static func start(title: String, subtitle: String, systemImage: String) -> LCLiveProgress? {
        guard LCLiveActivityAttributes.isInsideLiveContainer,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let attributes = LCLiveActivityAttributes.forCurrentApp(systemImage: systemImage, tintHex: tintHex)
        let state = LCLiveActivityAttributes.ContentState(title: title, subtitle: subtitle, progress: 0)
        do {
            let activity = try Activity.request(attributes: attributes,
                                                content: ActivityContent(state: state, staleDate: nil),
                                                pushType: nil)
            return LCLiveProgress(activity: activity, state: state)
        } catch {
            return nil
        }
    }

    func update(progress: Double) {
        change { $0.progress = min(max(progress, 0), 1) }
    }

    func update(subtitle: String) {
        // 文字變了（例如換下一個檔案）就立刻送，不等節流。
        change(force: true) { $0.subtitle = subtitle }
    }

    func end(success: Bool) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        var final = state
        final.subtitle = success ? "完成" : "未完成"
        if success { final.progress = 1 }
        final.systemImage = success ? "checkmark.circle.fill" : "xmark.circle.fill"
        lock.unlock()
        let activity = self.activity
        Task {
            // 完成後留在鎖定畫面幾秒，讓使用者看到結果再消失。
            await activity.end(ActivityContent(state: final, staleDate: nil),
                               dismissalPolicy: .after(.now.addingTimeInterval(4)))
        }
    }

    private func change(force: Bool = false, _ body: (inout LCLiveActivityAttributes.ContentState) -> Void) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        body(&state)
        let now = Date()
        guard force || now.timeIntervalSince(lastSent) >= Self.minimumInterval else {
            lock.unlock()
            return
        }
        lastSent = now
        let snapshot = state
        lock.unlock()
        let activity = self.activity
        Task { await activity.update(ActivityContent(state: snapshot, staleDate: nil)) }
    }
}
