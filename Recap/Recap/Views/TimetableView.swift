import SwiftUI

/// 課表的一節課。
struct TimetableEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// 1 = 星期日 … 7 = 星期六（Calendar 的 weekday）
    var weekday: Int
    /// 從 0:00 起算的分鐘
    var startMinute: Int
    var endMinute: Int
    var subject: SchoolSubject
    /// 自訂名稱（例如「英文辯論」），可留空
    var name: String = ""

    var title: String { name.isEmpty ? subject.title : name }

    var timeText: String { "\(Self.hm(startMinute))–\(Self.hm(endMinute))" }

    static func hm(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

    static let weekdayNames = ["", "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
}

extension AppSettings {
    /// 現在（或指定時間）是課表上的哪一節。開始前 10 分鐘到下課都算。
    func timetableEntry(at date: Date = .now) -> TimetableEntry? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return timetable
            .filter { $0.weekday == weekday && minute >= $0.startMinute - 10 && minute <= $0.endMinute }
            .min { abs($0.startMinute - minute) < abs($1.startMinute - minute) }
    }
}

struct TimetableView: View {
    @Environment(AppSettings.self) private var settings
    @State private var editing: TimetableEntry?

    var body: some View {
        List {
            Section {
                Text("填好課表後，按「開始上課」時會依現在的時間自動選科目；沒有課表的時段，下課後由 AI 判斷是什麼課。英文課會自動開即時字幕與翻譯。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(1...7, id: \.self) { day in
                let entries = settings.timetable.filter { $0.weekday == day }.sorted { $0.startMinute < $1.startMinute }
                if !entries.isEmpty {
                    Section(TimetableEntry.weekdayNames[day]) {
                        ForEach(entries) { entry in
                            Button { editing = entry } label: {
                                HStack {
                                    Label(entry.title, systemImage: entry.subject.symbol).foregroundStyle(.primary)
                                    Spacer()
                                    Text(entry.timeText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { entries[$0].id }
                            settings.timetable.removeAll { ids.contains($0.id) }
                            Haptics.warning()
                        }
                    }
                }
            }
            Section {
                Button("新增一節課", systemImage: "plus") {
                    let weekday = Calendar.current.component(.weekday, from: .now)
                    editing = TimetableEntry(weekday: (2...6).contains(weekday) ? weekday : 2, startMinute: 8 * 60 + 10, endMinute: 9 * 60, subject: .chinese)
                }
            }
        }
        .navigationTitle("課表")
        .sheet(item: $editing) { entry in
            TimetableEditor(entry: entry) { saved in
                if let index = settings.timetable.firstIndex(where: { $0.id == saved.id }) {
                    settings.timetable[index] = saved
                } else {
                    settings.timetable.append(saved)
                }
                Haptics.success()
            }
        }
    }
}

private struct TimetableEditor: View {
    @State var entry: TimetableEntry
    let onSave: (TimetableEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("星期", selection: $entry.weekday) {
                    ForEach(1...7, id: \.self) { Text(TimetableEntry.weekdayNames[$0]).tag($0) }
                }
                Picker("科目", selection: $entry.subject) {
                    ForEach(SchoolSubject.allCases.filter { $0 != .general }) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                TextField("自訂名稱（選填，例如英文辯論）", text: $entry.name)
                DatePicker("上課", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("下課", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
            }
            .navigationTitle("一節課")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        if entry.endMinute <= entry.startMinute { entry.endMinute = entry.startMinute + 50 }
                        onSave(entry)
                        dismiss()
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: entry.subject)
        }
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<TimetableEntry, Int>) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(entry[keyPath: keyPath]) * 60)
        } set: { date in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            entry[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        }
    }
}
