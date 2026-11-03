import EventKit
import EventKitUI
import MapKit
import SwiftUI
import UIKit

/// 快速動作：開網址、打電話、地圖、複製、提醒事項、行事曆。
@MainActor
enum ActionService {
    static func open(urlString: String) {
        guard let url = URL(string: EntityExtractor.normalizeURL(urlString)) else { return }
        UIApplication.shared.open(url)
    }

    static func call(_ phone: String) {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel:\(digits)") else { return }
        UIApplication.shared.open(url)
    }

    static func openInMaps(_ place: String) {
        var components = URLComponents(string: "maps://")
        components?.queryItems = [URLQueryItem(name: "q", value: place)]
        if let url = components?.url { UIApplication.shared.open(url) }
    }

    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// 新增提醒事項（需要完整取用提醒事項權限）。
    nonisolated static func addReminder(title: String, notes: String?, due: Date?) async throws {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw ActionError.remindersDenied }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        guard let calendar = store.defaultCalendarForNewReminders() else { throw ActionError.noReminderList }
        reminder.calendar = calendar
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
    }
}

enum ActionError: LocalizedError {
    case remindersDenied
    case noReminderList

    var errorDescription: String? {
        switch self {
        case .remindersDenied: "沒有提醒事項的權限，請到「設定 → Screenshots」開啟。"
        case .noReminderList: "找不到預設的提醒事項列表。"
        }
    }
}

/// 加入行事曆：用系統的事件編輯畫面（預填日期），使用者確認後才儲存。
struct EventEditor: UIViewControllerRepresentable {
    let title: String
    let notes: String?
    let start: Date
    let duration: TimeInterval?
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = notes
        event.startDate = start
        event.endDate = start.addingTimeInterval(duration ?? 3600)
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    @MainActor
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onFinish()
        }
    }
}
