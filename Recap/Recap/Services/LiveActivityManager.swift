import ActivityKit
import Foundation

/// 錄音時的即時動態（動態島＋鎖定畫面）。用 AudioRecordingIntent 從背景開始錄音時，系統要求一定要有。
///
/// 裝在 LiveContainer 裡時，系統會用 LiveContainer 的 widget 畫即時動態，認不得
/// RecordingActivityAttributes，所以改用 LiveContainer 的通用格式 LCLiveActivityAttributes。
@MainActor
final class LiveActivityManager {
    private var activity: Activity<RecordingActivityAttributes>?
    private var lcActivity: Activity<LCLiveActivityAttributes>?
    private var isLecture = false
    private var lastUpdate = Date.distantPast
    private let insideLiveContainer = LCLiveActivityAttributes.isInsideLiveContainer

    func start(mode: RecordingMode, state: RecordingActivityAttributes.ContentState) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        isLecture = mode == .lecture
        if insideLiveContainer {
            do {
                lcActivity = try Activity.request(
                    attributes: LCLiveActivityAttributes.forCurrentApp(
                        openURL: RecapURL.open,
                        systemImage: isLecture ? "captions.bubble.fill" : "waveform",
                        tintHex: Self.recordRed
                    ),
                    content: ActivityContent(state: lcState(state), staleDate: nil),
                    pushType: nil
                )
            } catch {
                appLog.error("即時動態啟動失敗：\(error.localizedDescription)")
            }
            return
        }
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
    /// `meter` 是每秒的波形更新：距離上次更新不到 0.8 秒就略過，避免跟其他更新疊在一起。
    func update(_ state: RecordingActivityAttributes.ContentState, throttle: Bool = false, alert: Bool = false, meter: Bool = false) {
        guard activity != nil || lcActivity != nil else { return }
        if throttle, !alert, Date().timeIntervalSince(lastUpdate) < 2 { return }
        if meter, Date().timeIntervalSince(lastUpdate) < 0.8 { return }
        lastUpdate = .now
        if let lcActivity {
            let content = ActivityContent(state: lcState(state), staleDate: nil)
            Task {
                if alert {
                    await lcActivity.update(content, alertConfiguration: Self.interruptedAlert)
                } else {
                    await lcActivity.update(content)
                }
            }
            return
        }
        guard let activity else { return }
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
        endLiveContainerActivity()
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

    // MARK: - LiveContainer

    private static let recordRed = "#FF3B30"
    private static let pauseOrange = "#FF9500"

    private static var interruptedAlert: AlertConfiguration {
        AlertConfiguration(title: "錄音被中斷", body: "按「繼續錄音」接著錄", sound: .default)
    }

    /// 把 Recap 的錄音狀態換成 LiveContainer 的通用格式。
    private func lcState(_ state: RecordingActivityAttributes.ContentState) -> LCLiveActivityAttributes.ContentState {
        let count = state.segmentCount
        let detail: String? = count > 0 ? (isLecture ? "\(count) 句" : "\(count) 段") : nil
        var subtitle = state.line.flatMap { $0.isEmpty ? nil : $0 }
        if subtitle == nil, let stopAt = state.stopAt, state.endedAt == nil {
            subtitle = "\(stopAt.formatted(date: .omitted, time: .shortened)) 自動停止"
        }

        if let endedAt = state.endedAt {
            return LCLiveActivityAttributes.ContentState(
                title: "錄音已儲存",
                subtitle: subtitle,
                tintHex: "#8E8E93",
                pausedElapsed: max(0, endedAt.timeIntervalSince(state.startedAt)),
                isFinished: true,
                detail: detail
            )
        }
        if state.isPaused {
            return LCLiveActivityAttributes.ContentState(
                title: state.manualPause ? "已暫停" : "錄音中斷",
                subtitle: subtitle ?? (state.manualPause ? nil : "打開 Recap 繼續錄音"),
                systemImage: "pause.fill",
                compactText: "暫停",
                tintHex: Self.pauseOrange,
                detail: detail
            )
        }
        return LCLiveActivityAttributes.ContentState(
            title: isLecture ? "課堂錄音" : "錄音中",
            subtitle: subtitle,
            timerStart: state.startedAt,
            tintHex: Self.recordRed,
            detail: detail,
            levels: state.levels.isEmpty ? nil : Array(state.levels.suffix(6))
        )
    }

    private func endLiveContainerActivity() {
        guard insideLiveContainer else { return }
        let current = lcActivity
        lcActivity = nil
        if let current {
            var final = current.content.state
            if !(final.isFinished ?? false) {
                let started = final.timerStart ?? .now
                final = LCLiveActivityAttributes.ContentState(
                    title: "錄音已儲存",
                    subtitle: final.subtitle,
                    tintHex: "#8E8E93",
                    pausedElapsed: max(0, Date().timeIntervalSince(started)),
                    isFinished: true,
                    detail: final.detail
                )
            }
            let content = ActivityContent(state: final, staleDate: nil)
            Task { await current.end(content, dismissalPolicy: .after(.now.addingTimeInterval(15 * 60))) }
        }
        // LiveContainer 裡其他 App 的即時動態也在這個清單裡，只清自己的
        let mine = Bundle.main.bundleURL.lastPathComponent
        for leftover in Activity<LCLiveActivityAttributes>.activities
        where leftover.id != current?.id && leftover.attributes.bundleName == mine {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
