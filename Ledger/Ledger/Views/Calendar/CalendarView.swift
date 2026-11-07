import SwiftUI
import SwiftData

enum HeatMode: String, CaseIterable, Identifiable {
    case net, expense, income
    var id: String { rawValue }
    var label: String {
        switch self {
        case .net: "收支"
        case .expense: "支出"
        case .income: "收入"
        }
    }
}

struct DayTotal {
    var expense: Double = 0
    var income: Double = 0
    var count = 0
    var net: Double { income - expense }
}

enum HeatColor {
    static let red = Color(hex: "#C62828")
    static let green = Color(hex: "#2E7D32")

    static func value(_ d: DayTotal?, mode: HeatMode) -> Double {
        guard let d else { return 0 }
        switch mode {
        case .net: return d.net
        case .expense: return -d.expense
        case .income: return d.income
        }
    }

    /// 支出越多越深紅，收入越多越深綠
    static func color(for v: Double, max m: Double) -> Color {
        guard v != 0, m > 0 else { return Color(.secondarySystemFill) }
        let t = min(sqrt(abs(v) / m), 1)
        return (v < 0 ? red : green).opacity(0.18 + 0.82 * t)
    }
}

struct CalendarView: View {
    @Query(sort: \Entry.date, order: .reverse) private var entries: [Entry]
    @Query(sort: \Category.order) private var categories: [Category]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @AppStorage("calendarGridMode") private var gridMode = false

    @State private var month = Date.now
    @State private var mode: HeatMode = .net
    @State private var selectedDay: Date?
    @State private var categoryFilter: UUID?
    @State private var editing: Entry?
    @State private var showStats = false

    private let cal = Calendar.current

    private var filtered: [Entry] {
        entries.filter { e in
            guard e.kind != .transfer else { return false }
            if let f = categoryFilter { return e.category?.main.id == f }
            return true
        }
    }

    private var totals: [Date: DayTotal] {
        var d: [Date: DayTotal] = [:]
        for e in filtered {
            let k = cal.startOfDay(for: e.date)
            var t = d[k] ?? DayTotal()
            if e.kind == .expense { t.expense += e.amount } else if e.kind == .income { t.income += e.amount }
            t.count += 1
            d[k] = t
        }
        return d
    }

    var body: some View {
        let totals = self.totals
        let range = heatRange
        let maxAbs = totals.filter { range.contains($0.key) }.map { abs(HeatColor.value($0.value, mode: mode)) }.max() ?? 0

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Group {
                        if gridMode {
                            MonthHeatGrid(month: month, totals: totals, mode: mode, maxAbs: maxAbs, selected: $selectedDay, hidden: hidden)
                                .cardStyle(padding: 14)
                                .transition(.blurReplace)
                        } else {
                            HeatStrip(range: range, month: month, totals: totals, mode: mode, maxAbs: maxAbs, selected: $selectedDay)
                                .transition(.blurReplace)
                        }
                    }
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: gridMode)

                    legend(maxAbs: maxAbs)
                    stats(totals: totals)
                    list
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .ledgerNavigation(mode == .net ? "日曆" : mode.label)
            .toolbar {
                HeaderTitle(title: mode == .net ? "日曆" : mode.label) {
                    Picker("顯示", selection: $mode.animation(.snappy)) {
                        ForEach(HeatMode.allCases) { Text($0.label).tag($0) }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("本月") { withAnimation(.snappy) { month = .now; selectedDay = nil } }
                        ForEach(1..<13) { i in
                            let d = DateText.addMonths(.now, -i)
                            Button(DateText.monthTitle(d)) { withAnimation(.snappy) { month = d; selectedDay = nil } }
                        }
                    } label: {
                        VStack(spacing: 0) {
                            Text(yearMonth(month)).font(.headline).monospacedDigit()
                            HStack(spacing: 2) {
                                Text(mode.label)
                                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                        .padding(.horizontal, 6)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("分類", selection: $categoryFilter.animation(.snappy)) {
                            Text("全部分類").tag(UUID?.none)
                            ForEach(categories.filter { !$0.isSub }) { c in
                                Label(c.name, systemImage: c.symbol).tag(Optional(c.id))
                            }
                        }
                    } label: {
                        Image(systemName: categoryFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    }
                    Button {
                        withAnimation { gridMode.toggle() }
                    } label: {
                        Image(systemName: gridMode ? "square.grid.3x3.fill" : "calendar")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Button { showStats = true } label: { Image(systemName: "chart.pie") }
                }
            }
            .sheet(item: $editing) { EntryEditor(entry: $0) }
            .sheet(isPresented: $showStats) { NavigationStack { StatsView() } }
            .sensoryFeedback(.selection, trigger: selectedDay)
        }
    }

    /// 熱度條顯示選定月份與前兩個月
    private var heatRange: DateInterval {
        let start = DateText.monthInterval(DateText.addMonths(month, -2)).start
        let end = DateText.monthInterval(month).end
        return DateInterval(start: start, end: end)
    }

    private func yearMonth(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month], from: d)
        return "\(String(c.year ?? 2026))年\(c.month ?? 1)月"
    }

    private func legend(maxAbs: Double) -> some View {
        HStack(spacing: 6) {
            if mode != .income {
                Text("支出").font(.caption).foregroundStyle(.secondary)
                ForEach([1.0, 0.6, 0.3, 0.1], id: \.self) { t in
                    RoundedRectangle(cornerRadius: 3).fill(HeatColor.color(for: -t * max(maxAbs, 1), max: max(maxAbs, 1))).frame(width: 14, height: 14)
                }
            }
            RoundedRectangle(cornerRadius: 3).fill(Color(.secondarySystemFill)).frame(width: 14, height: 14)
            if mode != .expense {
                ForEach([0.1, 0.3, 0.6, 1.0], id: \.self) { t in
                    RoundedRectangle(cornerRadius: 3).fill(HeatColor.color(for: t * max(maxAbs, 1), max: max(maxAbs, 1))).frame(width: 14, height: 14)
                }
                Text("收入").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = selectedDay {
                Button {
                    withAnimation(.snappy) { selectedDay = nil }
                } label: {
                    Label(DateText.dayHeader(d), systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func stats(totals: [Date: DayTotal]) -> some View {
        let iv = DateText.monthInterval(month)
        let monthDays = totals.filter { iv.contains($0.key) }
        let expense = monthDays.values.reduce(0) { $0 + $1.expense }
        let income = monthDays.values.reduce(0) { $0 + $1.income }
        let today = totals[cal.startOfDay(for: .now)]?.expense ?? 0
        let isCurrent = iv.contains(.now)
        let daysElapsed = isCurrent ? (cal.component(.day, from: .now)) : (cal.range(of: .day, in: .month, for: month)?.count ?? 30)
        let avg = expense / Double(max(daysElapsed, 1))
        // 上個月同期
        let prevIV = DateText.monthInterval(DateText.addMonths(month, -1))
        let prevEnd = isCurrent ? min(cal.date(byAdding: .day, value: daysElapsed, to: prevIV.start)!, prevIV.end) : prevIV.end
        let prev = totals.filter { $0.key >= prevIV.start && $0.key < prevEnd }.values.reduce(0) { $0 + $1.expense }
        let change: Double? = prev > 0 ? (expense - prev) / prev : nil

        return VStack(spacing: 12) {
            HStack {
                Image(systemName: "sum").foregroundStyle(Color.accentColor)
                Text(mode == .income ? "總收入" : "總支出").font(.headline)
                Spacer()
                MoneyText(value: mode == .income ? income : expense, hidden: hidden, font: .headline)
                    .foregroundStyle(.secondary)
            }
            .cardStyle(padding: 16)

            HStack(alignment: .top) {
                statCell("今天", today)
                Divider().frame(height: 40)
                statCell("平均", avg.rounded())
                Divider().frame(height: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text("與上個月相比").font(.subheadline).foregroundStyle(.secondary)
                    if let change {
                        HStack(spacing: 2) {
                            Image(systemName: change <= 0 ? "arrow.down.right" : "arrow.up.right")
                            Text(Money.percent(abs(change), digits: 1))
                        }
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(change <= 0 ? Color.blue : Color.red)
                    } else {
                        Text("—").font(.title3.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .cardStyle(padding: 16)
            .animation(.snappy, value: month)
        }
    }

    private func statCell(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            MoneyText(value: value, hidden: hidden, font: .title3.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        let iv = DateText.monthInterval(month)
        let source = filtered.filter { e in
            if let d = selectedDay { return cal.isDate(e.date, inSameDayAs: d) }
            return iv.contains(e.date)
        }
        .filter { mode == .net || (mode == .expense ? $0.kind == .expense : $0.kind == .income) }
        let grouped = Dictionary(grouping: source) { cal.startOfDay(for: $0.date) }
        let days = grouped.keys.sorted(by: >)

        return LazyVStack(alignment: .leading, spacing: 10) {
            if days.isEmpty {
                EmptyHint(symbol: "calendar", title: "沒有紀錄", message: selectedDay == nil ? "這個月還沒有記帳" : "這天沒有記帳")
            }
            ForEach(days, id: \.self) { day in
                let items = grouped[day]!.sorted { $0.date > $1.date }
                HStack {
                    Text(dayTitle(day))
                    Spacer()
                    Text(Money.format(items.reduce(0) { $0 + $1.signedAmount }, hidden: hidden, signed: true)).monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 6)
                VStack(spacing: 2) {
                    ForEach(items) { e in
                        Button { editing = e } label: {
                            EntryRow(entry: e, hidden: hidden)
                        }
                        .buttonStyle(.plain)
                        if e.id != items.last?.id { Divider().padding(.leading, 58) }
                    }
                }
                .cardStyle(padding: 14)
            }
        }
        .animation(.snappy, value: selectedDay)
    }

    private func dayTitle(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "EEE, M月d日"
        return f.string(from: d)
    }
}

/// 截圖風格的熱度格：每一欄是一週，由上而下是週一到週日
struct HeatStrip: View {
    var range: DateInterval
    var month: Date
    var totals: [Date: DayTotal]
    var mode: HeatMode
    var maxAbs: Double
    @Binding var selected: Date?

    private let cal: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 2 // 週一開始
        return c
    }()
    private let cell: CGFloat = 32
    private let gap: CGFloat = 6

    var body: some View {
        let weeks = buildWeeks()
        HStack(alignment: .top, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    // 月份標籤
                    HStack(spacing: gap) {
                        ForEach(weeks.indices, id: \.self) { i in
                            Text(monthLabel(weeks, i))
                                .font(.subheadline.weight(isCurrentMonthLabel(weeks, i) ? .bold : .regular))
                                .foregroundStyle(isCurrentMonthLabel(weeks, i) ? .primary : .secondary)
                                .fixedSize()
                                .frame(width: cell, alignment: .leading)
                        }
                    }
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(weeks.indices, id: \.self) { i in
                            VStack(spacing: gap) {
                                ForEach(weeks[i], id: \.self) { day in
                                    dayCell(day, index: i)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .defaultScrollAnchor(.trailing)
            .scrollClipDisabled()

            VStack(alignment: .leading, spacing: gap) {
                Text(" ").font(.subheadline)
                ForEach(["週一", "週二", "週三", "週四", "週五", "週六", "週日"], id: \.self) { w in
                    Text(w).font(.subheadline).foregroundStyle(.secondary).frame(height: cell)
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date, index: Int) -> some View {
        let inRange = range.contains(day)
        let future = day > Date.now
        let isToday = cal.isDateInToday(day)
        let isSelected = selected.map { cal.isDate($0, inSameDayAs: day) } ?? false
        let v = HeatColor.value(totals[day], mode: mode)
        if !inRange {
            Color.clear.frame(width: cell, height: cell)
        } else {
            Button {
                withAnimation(.snappy) { selected = isSelected ? nil : day }
            } label: {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(future ? Color.clear : HeatColor.color(for: v, max: maxAbs))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(future ? Color(.separator) : (isSelected ? Color.primary : .clear), lineWidth: isSelected ? 2.5 : 1)
                    }
                    .overlay {
                        if isToday { Circle().fill(Color.primary).frame(width: 6, height: 6) }
                    }
                    .frame(width: cell, height: cell)
                    .scaleEffect(isSelected ? 1.12 : 1)
            }
            .buttonStyle(.plain)
            .disabled(future)
            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.012), value: maxAbs)
        }
    }

    private func buildWeeks() -> [[Date]] {
        guard let firstWeek = cal.dateInterval(of: .weekOfYear, for: range.start) else { return [] }
        var weeks: [[Date]] = []
        var start = firstWeek.start
        while start < range.end {
            weeks.append((0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) })
            start = cal.date(byAdding: .day, value: 7, to: start)!
        }
        return weeks
    }

    private func monthLabel(_ weeks: [[Date]], _ i: Int) -> String {
        // 這一週包含某月 1 號就標示月份
        guard let first = weeks[i].first(where: { cal.component(.day, from: $0) == 1 && range.contains($0) }) else {
            if i == 0, let d = weeks[0].first(where: { range.contains($0) }) { return "\(cal.component(.month, from: d))月" }
            return ""
        }
        return "\(cal.component(.month, from: first))月"
    }

    private func isCurrentMonthLabel(_ weeks: [[Date]], _ i: Int) -> Bool {
        weeks[i].contains { cal.component(.day, from: $0) == 1 && cal.isDate($0, equalTo: month, toGranularity: .month) }
    }
}

/// 傳統月曆，每天用顏色顯示收支
struct MonthHeatGrid: View {
    var month: Date
    var totals: [Date: DayTotal]
    var mode: HeatMode
    var maxAbs: Double
    @Binding var selected: Date?
    var hidden: Bool

    private let cal = Calendar.current

    var body: some View {
        let iv = DateText.monthInterval(month)
        let firstWeekday = (cal.component(.weekday, from: iv.start) + 5) % 7 // 週一 = 0
        let days = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let monthMax = totals.filter { iv.contains($0.key) }.map { abs(HeatColor.value($0.value, mode: mode)) }.max() ?? maxAbs

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(0..<firstWeekday, id: \.self) { _ in Color.clear.frame(height: 54) }
            ForEach(1...days, id: \.self) { d in
                let date = cal.date(byAdding: .day, value: d - 1, to: iv.start)!
                let t = totals[date]
                let v = HeatColor.value(t, mode: mode)
                let isSelected = selected.map { cal.isDate($0, inSameDayAs: date) } ?? false
                let strong = monthMax > 0 && sqrt(abs(v) / monthMax) > 0.55
                Button {
                    withAnimation(.snappy) { selected = isSelected ? nil : date }
                } label: {
                    VStack(spacing: 2) {
                        Text("\(d)")
                            .font(.callout.weight(cal.isDateInToday(date) ? .heavy : .medium))
                        if let t, t.count > 0, !hidden {
                            Text(shortAmount(v))
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                    .foregroundStyle(strong ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(HeatColor.color(for: v, max: monthMax), in: .rect(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2.5)
                    }
                }
                .buttonStyle(.plain)
                .disabled(date > .now)
                .opacity(date > .now ? 0.4 : 1)
            }
        }
    }

    private func shortAmount(_ v: Double) -> String {
        let a = abs(v)
        let s = a >= 10000 ? String(format: "%.1f萬", a / 10000) : Money.format(a)
        return v < 0 ? "-" + s : (v > 0 ? "+" + s : "0")
    }
}
