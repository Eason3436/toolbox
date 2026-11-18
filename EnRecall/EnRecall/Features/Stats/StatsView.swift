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

private struct HeatmapCard: View {
    /// 91 天，最舊的在前
    let days: [DayCount]

    var body: some View {
        let maxCount = days.map(\.count).max() ?? 0
        let columns = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 3) {
                ForEach(columns.indices, id: \.self) { column in
                    VStack(spacing: 3) {
                        ForEach(columns[column]) { day in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.er.heat[StatsCalculator.heatLevel(day.count, max: maxCount)])
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            HStack(spacing: 4) {
                Spacer()
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
        .accessibilityElement()
        .accessibilityLabel("近 90 天複習熱力圖")
        .accessibilityValue("共 \(days.map(\.count).reduce(0, +)) 張，最多一天 \(maxCount) 張")
    }
}

// MARK: - 每日長條

private struct DailyBarChart: View {
    let days: [DayCount]
    let annotate: Bool

    private var labelFormat: Date.FormatStyle {
        annotate ? Date.FormatStyle().weekday(.narrow) : Date.FormatStyle().month(.defaultDigits).day()
    }

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        Chart(days) { day in
            BarMark(
                x: .value("日期", day.date, unit: .day),
                y: .value("張數", day.count)
            )
            .foregroundStyle(day.date == today ? Color.er.text : Color.er.outlineStrong)
            .cornerRadius(3)
            .annotation(position: .top, spacing: 2) {
                if annotate && day.count > 0 {
                    Text(day.count, format: .number)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color.er.textSecondary)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: annotate ? 1 : 7)) { _ in
                AxisValueLabel(format: labelFormat, centered: true)
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 160)
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
