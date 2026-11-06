import Foundation
import UserNotifications

/// 本地通知管理：後臺同步失敗時通知使用者。
enum NotificationManager {
    static let requestIdentifier = "sync-failed"

    /// 請求通知授權。
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // 授權失敗時靜默跳過，不影響主功能
        }
    }

    /// 檢查是否已授權。
    static func isAuthorized() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus == .authorized)
            }
        }
    }

    /// 傳送同步失敗本地通知。
    static func notifySyncFailure(_ errorDescription: String) async {
        guard await isAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = "HealthMi 同步失敗"
        content.body = "同步出錯：\(errorDescription)，請開啟 App 檢視"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: requestIdentifier, content: content, trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // 通知傳送失敗不影響主功能
        }
    }
}
