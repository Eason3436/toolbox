import ActivityKit
import Foundation

/// 錄音時的即時動態（動態島＋鎖定畫面）。用 AudioRecordingIntent 從背景開始錄音時，系統要求一定要有。
@MainActor
final class LiveActivityManager {
    private var activity: Activity<RecordingActivityAttributes>?
    private var lastUpdate = Date.distantPast

    func start(mode: RecordingMode, state: RecordingActivityAttributes.ContentState) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(mode: mode.rawValue),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            appLog.error("即時動態啟動失敗：\(error.localizedDescription)")
        }
    }

    /// `throttle` 為 true 時最多每 2 秒更新一次（課堂翻譯用）。
    func update(_ state: RecordingActivityAttributes.ContentState, throttle: Bool = false) {
        guard let activity else { return }
        if throttle, Date().timeIntervalSince(lastUpdate) < 2 { return }
        lastUpdate = .now
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        let current = activity
        activity = nil
        Task { await current?.end(nil, dismissalPolicy: .immediate) }
        // 清掉 App 被砍掉時殘留的
        for leftover in Activity<RecordingActivityAttributes>.activities where leftover.id != current?.id {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
