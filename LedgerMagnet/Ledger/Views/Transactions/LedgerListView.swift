import SwiftUI

/// 「明細」分頁：清單和日曆兩種看法，用右上角的按鈕切換
struct LedgerListView: View {
    @AppStorage(LedgerListView.modeKey) private var calendarMode = false
    static let modeKey = "ledgerCalendarMode"

    var body: some View {
        ZStack {
            if calendarMode {
                CalendarView().transition(.opacity)
            } else {
                EntriesView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: calendarMode)
    }
}

/// 清單／日曆切換按鈕
struct LedgerModeToggle: View {
    @AppStorage(LedgerListView.modeKey) private var calendarMode = false
    var body: some View {
        Button {
            calendarMode.toggle()
        } label: {
            Image(systemName: calendarMode ? "list.bullet" : "calendar")
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(calendarMode ? "清單" : "日曆")
    }
}
