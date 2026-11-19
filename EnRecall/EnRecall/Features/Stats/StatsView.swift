import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    enum ChartRange: String, CaseIterable, Identifiable {
        case week
        case month

        var id: String { rawValue }
        var title: String { self == .week ? "週" : "月" }
        var days: Int { self == .week ? 7 : 30 }
    }

    @Query(sort: \Deck.sortIndex) private var decks: [Deck]
    @Query(sort: \ReviewLog.reviewedAt) private var logs: [ReviewLog]
    @State private var range: ChartRange = .week

    var body: some View {
        let today = StudyPlanner.todaysLogs(logs, now: Date())
        let streak = StatsCalculator.streak(logs)
        let heat = StatsCalculator.dailyCounts(logs, days: 91)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                HStack(spacing: Theme.Spacing.stack) {
                    StatCard(title: "今日複習", value: today.count)
                    StatCard(title: "今日新學", value: today.filter(\.wasNew).count)
                    StatCard(title: "連續", value: streak, unit: "天")
                }

                SectionHeader(title: "近 90 天", trailing: "共 \(heat.map(\.count).reduce(0, +).formatted()) 張")
                HeatmapCard(days: heat)

                HStack(alignment: .lastTextBaseline) {
                    SectionHeader(title: "每日複習")
                    Spacer()
                    Picker("範圍", selection: $range) {
                        ForEach(ChartRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                }
                DailyBarChart(days: StatsCalculator.dailyCounts(logs, days: range.days), annotate: range == .week)
                    .erCard(elevated: true)

                SectionHeader(title: "各牌組熟練度")
                if decks.isEmpty {
                    EmptyLine("還沒有牌組")
                } else {
                    MasteryChart(decks: decks)
                        .erCard(elevated: true)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 24)
        }
        .erPageBackground()
        .navigationTitle("紀錄")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: "我今天在 EnRecall 複習了 \(today.count) 張單字，已經連續 \(streak) 天") {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享")
            }
        }
    }
}

// MARK: - 熱力圖

/// 近 90 天：一欄一週（週一在上、週日在下），左邊標一三五日、上面在每月第一週標月份。
/// 今天加一圈框，本週還沒到的日子不畫。點一格在下面顯示那天幾張，預設今天
private struct HeatmapCard: View {
    /// 91 天，最舊的在前，最後一天是今天
    let days: [DayCount]

    @State private var selected: Date?
    @State private var width: CGFloat = 0

    private let spacing: CGFloat = 4
    private let maxCell: CGFloat = 18
    private let labelWidth: CGFloat = 16
    private let monthHeight: CGFloat = 16

    /// 週一開始（不跟著地區的每週第一天）
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    private struct Week: Identifiable {
        let id: Date
        /// 週一到週日，nil＝不在範圍裡（還沒到、或比 90 天更早）
        let days: [DayCount?]
        /// 這週有某個月的 1 號：那欄標月份
        let monthStart: Date?
    }

    private var weeks: [Week] {
        guard let first = days.first?.date, let last = days.last?.date,
              let start = calendar.dateInterval(of: .weekOfYear, for: first)?.start else { return [] }
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Week] = []
        var weekStart = start
        while weekStart <= last {
            var items: [DayCount?] = []
            var monthStart: Date?
            for offset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
                    items.append(nil)
                    continue
                }
                items.append(byDate[date])
                if calendar.component(.day, from: date) == 1, date >= first, date <= last {
                    monthStart = date
                }
            }
            result.append(Week(id: weekStart, days: items, monthStart: monthStart))
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { break }
            weekStart = next
        }
        return result
    }

    var body: some View {
        let weeks = weeks
        let maxCount = days.map(\.count).max() ?? 0
        let today = days.last
        let shown = days.first { $0.date == selected } ?? today
        // 格子最大 18pt；卡片比較窄的手機就一起縮小，整張圖不超出卡片
        let available = width - labelWidth - spacing
        let fitted = weeks.isEmpty ? maxCell : (available - spacing * CGFloat(weeks.count - 1)) / CGFloat(weeks.count)
        let cell = max(8, min(maxCell, floor(fitted)))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: spacing) {
                weekdayLabels(cell: cell)
                ForEach(weeks) { week in
                    VStack(spacing: spacing) {
                        Text(week.monthStart.map { $0.formatted(.dateTime.month(.abbreviated)) } ?? "")
                            .font(.caption2)
                            .foregroundStyle(Color.er.textTertiary)
                            .fixedSize()
                            .frame(width: cell, height: monthHeight, alignment: .leading)
                        ForEach(0..<7, id: \.self) { row in
                            if let day = week.days[row] {
                                cellView(day, size: cell, maxCount: maxCount, isToday: day.date == today?.date, isSelected: day.date == shown?.date)
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }

            HStack(spacing: 4) {
                if let shown {
                    Text("\(shown.date.formatted(.dateTime.month(.defaultDigits).day()))（\(shown.date.formatted(.dateTime.weekday(.narrow)))）・\(shown.count.formatted()) 張")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.er.text)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                Text("少")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.er.heat[level])
                        .frame(width: 10, height: 10)
                }
                Text("多")
            }
            .font(.caption2)
            .foregroundStyle(Color.er.textTertiary)
        }
        .erCard(elevated: true)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("近 90 天複習熱力圖")
    }

    /// 左邊只標一、三、五、日
    private func weekdayLabels(cell: CGFloat) -> some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return VStack(alignment: .leading, spacing: spacing) {
            Color.clear.frame(width: labelWidth, height: monthHeight)
            ForEach(0..<7, id: \.self) { row in
                // row 0 是週一；symbols 從週日開始
                Text(row.isMultiple(of: 2) ? symbols[(row + 1) % 7] : "")
                    .font(.caption2)
                    .foregroundStyle(Color.er.textTertiary)
                    .frame(width: labelWidth, height: cell, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private func cellView(_ day: DayCount, size: CGFloat, maxCount: Int, isToday: Bool, isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return shape
            .fill(Color.er.heat[StatsCalculator.heatLevel(day.count, max: maxCount)])
            .frame(width: size, height: size)
            .overlay {
                if isToday {
                    shape.strokeBorder(Color.er.primary.opacity(0.45), lineWidth: 2)
                } else if isSelected {
                    shape.strokeBorder(Color.er.textSecondary, lineWidth: 1.5)
                }
            }
            .contentShape(shape)
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) { selected = day.date }
            }
            .accessibilityElement()
            .accessibilityLabel(day.date.formatted(.dateTime.month().day().weekday()))
            .accessibilityValue("\(day.count.formatted()) 張")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 每日長條

/// 堆疊長條：深色＝複習、淺色＝新學。0 張的日子畫一條 3pt 的淡線；週檢視每條上面寫總數，今天粗體
private struct DailyBarChart: View {
    let days: [DayCount]
    let annotate: Bool

    private let plotHeight: CGFloat = 140

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let maxCount = days.map(\.count).max() ?? 0
        // 上面留一點空間放數字
        let yMax = Double(max(maxCount, 4)) * 1.18
        let zeroHeight = yMax * 3 / Double(plotHeight)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Spacer()
                legend(Color.er.text, "複習")
                legend(Color.er.outlineStrong, "新學")
            }
            .font(.caption)
            .foregroundStyle(Color.er.textSecondary)

            Chart(days) { day in
                if day.count == 0 {
                    BarMark(
                        x: .value("日期", day.date, unit: .day),
                        yStart: .value("張數", 0.0),
                        yEnd: .value("張數", zeroHeight)
                    )
                    .foregroundStyle(Color.er.outline)
                    .cornerRadius(1.5)
                } else {
                    BarMark(
                        x: .value("日期", day.date, unit: .day),
                        yStart: .value("張數", 0.0),
                        yEnd: .value("張數", Double(day.reviewCount))
                    )
                    .foregroundStyle(Color.er.text)
                    .cornerRadius(day.newCount == 0 ? 3 : 0)
                    BarMark(
                        x: .value("日期", day.date, unit: .day),
                        yStart: .value("張數", Double(day.reviewCount)),
                        yEnd: .value("張數", Double(day.count))
                    )
                    .foregroundStyle(Color.er.outlineStrong)
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        if annotate {
                            Text(day.count, format: .number)
                                .font(.caption2.weight(day.date == today ? .bold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(day.date == today ? Color.er.text : Color.er.textSecondary)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...yMax)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: annotate ? 1 : 7)) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            axisLabel(date, isToday: Calendar.current.isDate(date, inSameDayAs: today))
                        }
                    }
                }
            }
            .frame(height: plotHeight + 20)
        }
    }

    /// 週：週一、週二…，最後一天寫「今天」；月：日期
    @ViewBuilder
    private func axisLabel(_ date: Date, isToday: Bool) -> some View {
        if isToday {
            Text("今天").fontWeight(.bold).foregroundStyle(Color.er.text)
        } else if annotate {
            Text(date, format: .dateTime.weekday(.abbreviated))
        } else {
            Text(date, format: .dateTime.month(.defaultDigits).day())
        }
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
        }
    }
}

// MARK: - 熟練度

private struct MasteryRow: Identifiable {
    let id: String
    let name: String
    let mastered: Int
    let learning: Int
    let fresh: Int

    var total: Int { mastered + learning + fresh }
}

/// 每個牌組一列：名稱、已熟悉／總數，下面一條依比例分段的長條（每列各自滿版，看的是比例）
private struct MasteryChart: View {
    let decks: [Deck]

    private var rows: [MasteryRow] {
        decks.map { deck in
            var mastered = 0
            var fresh = 0
            var learning = 0
            for card in deck.activeCards {
                if card.isMastered {
                    mastered += 1
                } else if card.isNew {
                    fresh += 1
                } else {
                    learning += 1
                }
            }
            return MasteryRow(id: deck.id, name: deck.name, mastered: mastered, learning: learning, fresh: fresh)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(rows) { row in
                MasteryRowView(row: row)
            }

            HStack(spacing: 14) {
                legend(Color.er.mastered, "已熟悉")
                legend(Color.er.learning, "學習中")
                legend(Color.er.fresh, "新卡")
            }
            .font(.caption)
            .foregroundStyle(Color.er.textSecondary)
            .padding(.top, 2)
        }
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
        }
    }
}

private struct MasteryRowView: View {
    let row: MasteryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(row.mastered.formatted()) / \(row.total.formatted())")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.er.textSecondary)
            }
            bar
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue("已熟悉 \(row.mastered.formatted()) 張，學習中 \(row.learning.formatted()) 張，新卡 \(row.fresh.formatted()) 張")
    }

    private var bar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let total = CGFloat(max(row.total, 1))
            HStack(spacing: 0) {
                segment(Color.er.mastered, CGFloat(row.mastered) / total * width)
                segment(Color.er.learning, CGFloat(row.learning) / total * width)
                segment(Color.er.fresh, CGFloat(row.fresh) / total * width)
            }
            .frame(width: width, alignment: .leading)
            .background(Color.er.fill)
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private func segment(_ color: Color, _ width: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: width)
    }
}

#Preview("淺色") {
    NavigationStack {
        StatsView()
    }
    .previewEnvironment()
}

#Preview("深色") {
    NavigationStack {
        StatsView()
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
