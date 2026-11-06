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
    /// `alert` 為 true 時會亮起動態島並震動提醒（例如錄音被打斷）。
    func update(_ state: RecordingActivityAttributes.ContentState, throttle: Bool = false, alert: Bool = false) {
        guard let activity else { return }
        if throttle, !alert, Date().timeIntervalSince(lastUpdate) < 2 { return }
        lastUpdate = .now
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            if alert {
                await activity.update(content, alertConfiguration: AlertConfiguration(
                    title: "錄音被中斷",
                    body: "按「繼續錄音」接著錄",
                    sound: .default
                ))
            } else {
                await activity.update(content)
            }
        }
    }

    func end() {
        let current = activity
        activity = nil
        // 錄完留在鎖定畫面 15 分鐘，方便點進去看（設計規範建議 15–30 分鐘）
        if let current {
            var final = current.content.state
            final.endedAt = .now
            final.isPaused = false
            final.manualPause = false
            Task { await current.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(15 * 60))) }
        }
        // 清掉 App 被砍掉時殘留的
        for leftover in Activity<RecordingActivityAttributes>.activities where leftover.id != current?.id {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
