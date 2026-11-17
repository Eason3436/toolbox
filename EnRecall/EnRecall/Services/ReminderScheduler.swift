import Foundation
import SwiftData
import UserNotifications

/// 每日提醒：App 在背景跑不了程式，所以每次用完都先排好接下來 7 天的通知，
/// 每一則的字數照「到那時候還有多少要背」算；那天沒東西要背就不排。
/// 裝在 LiveContainer 裡時，要在 LiveContainer 打開這個 App 的「修復本地通知」，通知才會出現（顯示成 LiveContainer 的通知）
enum ReminderScheduler {
    static let prefix = "enrecall.reminder."
    static let days = 7

    /// 問通知權限；拒絕過就回 false
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    @MainActor
    static func reschedule(context: ModelContext, now: Date = Date(), calendar: Calendar = .current) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.reminderEnabled) else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }

        let seconds = defaults.object(forKey: SettingsKey.reminderSeconds) == nil
            ? AppDefaults.reminderSeconds
            : defaults.integer(forKey: SettingsKey.reminderSeconds)
        let forecast = StudyForecast.load(context: context, now: now, calendar: calendar)
        for (fire, counts) in plan(forecast: forecast, reminderSeconds: seconds, now: now, calendar: calendar) {
            let content = UNMutableNotificationContent()
            content.title = "背單字"
            content.body = message(counts)
            content.sound = .default
            content.threadIdentifier = "enrecall.reminder"
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            let id = prefix + fire.formatted(.iso8601.year().month().day())
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    /// 接下來每天的提醒時間，和那時候還有多少要背（沒有要背的那天不排）
    static func plan(forecast: StudyForecast, reminderSeconds: Int, now: Date, calendar: Calendar = .current) -> [(Date, StudyCounts)] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = calendar.date(byAdding: .second, value: reminderSeconds, to: day),
                  fire > now.addingTimeInterval(60)
            else { return nil }
            let counts = forecast.counts(at: fire, calendar: calendar)
            return counts.total > 0 ? (fire, counts) : nil
        }
    }

    static func message(_ counts: StudyCounts) -> String {
        switch (counts.due, counts.new) {
        case (0, let new): "今天的 \(new) 個新字還沒背"
        case (let due, 0): "還有 \(due) 張要複習"
        case let (due, new): "還有 \(due) 張要複習、\(new) 個新字"
        }
    }
}
