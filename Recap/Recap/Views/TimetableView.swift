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
    @State private var pasting = false

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
        .toolbar {
            Button("貼上課表", systemImage: "doc.on.clipboard") { pasting = true }
        }
        .sheet(isPresented: $pasting) {
            TimetablePasteView { entries, replace in
                if replace { settings.timetable = entries } else { settings.timetable += entries }
                Haptics.success()
            }
        }
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

/// 貼上文字一次匯入整份課表，一行一節：「星期一 08:10-09:00 數學」（星期也可以寫「一」「週一」「Mon」）。
enum TimetableParser {
    static func parse(_ text: String) -> [TimetableEntry] {
        var result: [TimetableEntry] = []
        var currentDay: Int?
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let found = weekday(prefixOf: line) {
                currentDay = found.0
                line = found.1
            }
            guard let day = currentDay,
                  let range = line.range(of: #"(\d{1,2}):?(\d{2})\s*[-–~～至]\s*(\d{1,2}):?(\d{2})"#, options: .regularExpression) else { continue }
            let digits = line[range].split(whereSeparator: { !$0.isNumber }).map(String.init)
            // 0810-0900 會被拆成 ["0810","0900"]；08:10-09:00 會是 ["08","10","09","00"]
            let numbers: [Int]
            if digits.count == 4 { numbers = digits.compactMap { Int($0) } }
            else if digits.count == 2, digits.allSatisfy({ $0.count >= 3 }) {
                numbers = digits.flatMap { d -> [Int] in [Int(d.dropLast(2)) ?? 0, Int(d.suffix(2)) ?? 0] }
            } else { continue }
            guard numbers.count == 4 else { continue }
            let start = numbers[0] * 60 + numbers[1]
            let end = numbers[2] * 60 + numbers[3]
            guard end > start else { continue }
            let name = line.replacingCharacters(in: range, with: " ")
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "：:,，、|")))
            guard !name.isEmpty else { continue }
            result.append(TimetableEntry(weekday: day, startMinute: start, endMinute: end, subject: subject(for: name), name: name))
        }
        return result
    }

    /// 課名對到科目（對不到就是一般課，保留課名）
    static func subject(for name: String) -> SchoolSubject {
        if let s = SchoolSubject.match(name) { return s }
        if name.contains("國語") || name.contains("文學") || name.contains("國文") { return .chinese }
        if name.contains("英") { return .english }
        if name.contains("數") { return .math }
        return .general
    }

    private static let dayNames: [(String, Int)] = [
        ("星期日", 1), ("星期天", 1), ("星期一", 2), ("星期二", 3), ("星期三", 4), ("星期四", 5), ("星期五", 6), ("星期六", 7),
        ("週日", 1), ("週一", 2), ("週二", 3), ("週三", 4), ("週四", 5), ("週五", 6), ("週六", 7),
        ("周日", 1), ("周一", 2), ("周二", 3), ("周三", 4), ("周四", 5), ("周五", 6), ("周六", 7),
        ("Sun", 1), ("Mon", 2), ("Tue", 3), ("Wed", 4), ("Thu", 5), ("Fri", 6), ("Sat", 7),
        ("日", 1), ("一", 2), ("二", 3), ("三", 4), ("四", 5), ("五", 6), ("六", 7),
    ]

    private static func weekday(prefixOf line: String) -> (Int, String)? {
        for (name, day) in dayNames where line.hasPrefix(name) {
            let rest = line.dropFirst(name.count)
            // 單字「一」「二」後面要接空白、冒號或數字，避免把課名開頭誤認成星期
            if name.count == 1, let next = rest.first, !(next.isWhitespace || next.isNumber || "：:".contains(next)) { continue }
            return (day, String(rest).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "：:"))))
        }
        return nil
    }
}

struct TimetablePasteView: View {
    let onImport: ([TimetableEntry], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var replace = true

    private var parsed: [TimetableEntry] { TimetableParser.parse(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .font(.callout.monospaced())
                    Button("從剪貼簿貼上", systemImage: "doc.on.clipboard") { text = UIPasteboard.general.string ?? text }
                } footer: {
                    Text("一行一節，例如「星期一 08:10-09:00 數學」。同一天的課可以先寫一行「星期一」，下面每行只寫「0810-0900 數學」。課名裡有國文、英文、數學、物理、化學等字會自動對到科目。")
                }
                Section {
                    Toggle("取代目前的課表", isOn: $replace)
                    LabeledContent("認得的課", value: "\(parsed.count) 節")
                }
                if !parsed.isEmpty {
                    Section("預覽") {
                        ForEach(parsed.prefix(60)) { entry in
                            HStack {
                                Text(TimetableEntry.weekdayNames[entry.weekday]).foregroundStyle(.secondary)
                                Text(entry.timeText).font(.callout.monospacedDigit())
                                Text(entry.title)
                                Spacer()
                                Image(systemName: entry.subject.symbol).foregroundStyle(.tint)
                            }
                            .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("貼上課表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("匯入") { onImport(parsed, replace); dismiss() }.disabled(parsed.isEmpty)
                }
            }
        }
    }
}
