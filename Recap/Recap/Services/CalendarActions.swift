import EventKit
import EventKitUI
import SwiftUI

/// 把待辦加到「提醒事項」、把行程加到「行事曆」。
@MainActor
enum CalendarActions {
    static let store = EKEventStore()

    /// 從文字找日期時間（例如「明天下午三點」「11/20 14:00」）。
    static func detectDate(in text: String) -> (date: Date, hasTime: Bool)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range), let date = match.date else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        // 沒寫時間時 NSDataDetector 通常給中午 12:00
        let hasTime = !(comps.hour == 12 && comps.minute == 0)
        return (date, hasTime)
    }

    /// 直接新增一筆提醒事項。
    static func addReminder(_ text: String, notes: String? = nil) async throws {
        guard try await store.requestFullAccessToReminders() else { throw CalendarError.denied("提醒事項") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let found = detectDate(in: text) {
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: found.date)
            if found.hasTime {
                comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: found.date)
                reminder.addAlarm(EKAlarm(absoluteDate: found.date))
            }
            reminder.dueDateComponents = comps
        }
        try store.save(reminder, commit: true)
    }

    /// 準備一個行事曆事件（交給系統的編輯畫面讓使用者確認）。
    static func draftEvent(_ text: String, notes: String?) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = text
        event.notes = notes
        if let found = detectDate(in: text) {
            if found.hasTime {
                event.startDate = found.date
                event.endDate = found.date.addingTimeInterval(3600)
            } else {
                event.isAllDay = true
                event.startDate = Calendar.current.startOfDay(for: found.date)
                event.endDate = event.startDate.addingTimeInterval(3600)
            }
        } else {
            let start = Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
            event.startDate = start
            event.endDate = start.addingTimeInterval(3600)
        }
        return event
    }
}

enum CalendarError: LocalizedError {
    case denied(String)
    var errorDescription: String? {
        switch self {
        case .denied(let app): "沒有「\(app)」權限。請到「設定 → Recap」打開。"
        }
    }
}

/// 系統的新增行程畫面（不需要行事曆讀取權限）。
struct EventEditor: UIViewControllerRepresentable {
    let event: EKEvent
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = CalendarActions.store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }
}

private struct EventDraft: Identifiable {
    let id = UUID()
    let event: EKEvent
}

/// 待辦清單：每項可以加到提醒事項或行事曆。
struct TodoList: View {
    let items: [String]
    /// 放進備註的來源說明，例如「Recap 11/4 課堂：經濟學」
    var source: String? = nil
    @State private var draft: EventDraft?
    @State private var message: String?
    @State private var added: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: added.contains(item) ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(.green)
                        .frame(width: 14)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Menu {
                        Button("加到提醒事項", systemImage: "checklist") { addReminder(item) }
                        Button("加到行事曆", systemImage: "calendar.badge.plus") {
                            draft = EventDraft(event: CalendarActions.draftEvent(item, notes: source))
                        }
                    } label: {
                        Image(systemName: "plus.circle").font(.body).foregroundStyle(.tint)
                    }
                }
            }
            if items.count > 1 {
                Button("全部加到提醒事項", systemImage: "checklist") {
                    Task {
                        for item in items where !added.contains(item) { await add(item) }
                    }
                }
                .font(.footnote)
                .buttonStyle(.glass)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $draft) { draft in
            EventEditor(event: draft.event).ignoresSafeArea()
        }
    }

    private func addReminder(_ item: String) {
        Task { await add(item) }
    }

    private func add(_ item: String) async {
        do {
            try await CalendarActions.addReminder(item, notes: source)
            added.insert(item)
            message = "已加到提醒事項"
        } catch {
            message = error.localizedDescription
        }
    }
}
