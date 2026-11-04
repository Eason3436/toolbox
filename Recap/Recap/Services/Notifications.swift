import Foundation
import UserNotifications

/// 本機通知：排程開始提醒、錄音中斷提醒。
enum Notifications {
    static let scheduleCategory = "SCHEDULE_START"
    static let resumeCategory = "RESUME_RECORDING"
    static let startAction = "START"
    static let resumeAction = "RESUME"
    private static let resumeID = "resume-reminder"

    static func registerCategories() {
        let start = UNNotificationAction(identifier: startAction, title: "開始錄音", options: [.foreground])
        let resume = UNNotificationAction(identifier: resumeAction, title: "繼續錄音", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: scheduleCategory, actions: [start], intentIdentifiers: []),
            UNNotificationCategory(identifier: resumeCategory, actions: [resume], intentIdentifiers: []),
        ])
    }

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// 重新排好所有排程的開始通知（每週重複）。
    static func reschedule(_ rules: [ScheduleRule], enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("schedule-") })
        guard enabled else { return }
        for rule in rules where rule.enabled {
            for weekday in rule.weekdays {
                let content = UNMutableNotificationContent()
                content.title = "\(rule.name)：該開始錄音了"
                content.body = "點一下開始\(rule.mode.title)，會錄到 \(ScheduleRule.timeText(rule.endMinute))。設好捷徑自動化就不用點。"
                content.sound = .default
                content.categoryIdentifier = scheduleCategory
                content.userInfo = ["ruleID": rule.id.uuidString, "mode": rule.mode.rawValue]
                content.interruptionLevel = .timeSensitive
                var components = DateComponents()
                components.weekday = weekday
                components.hour = rule.startMinute / 60
                components.minute = rule.startMinute % 60
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                let request = UNNotificationRequest(identifier: "schedule-\(rule.id.uuidString)-\(weekday)", content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
    }

    static func postResumeReminder() {
        let content = UNMutableNotificationContent()
        content.title = "錄音暫停了"
        content.body = "錄音被來電或其他 App 打斷，系統不讓 App 自己在背景重新開麥克風。點一下繼續錄音。"
        content.sound = .default
        content.categoryIdentifier = resumeCategory
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: resumeID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clearResumeReminder() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [resumeID])
    }
}
