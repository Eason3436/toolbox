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
                AxisValueLabel(format: labelFormat)
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 160)
    }
}

// MARK: - 熟練度

private struct MasteryRow: Identifiable {
    let deck: String
    let status: String
    let count: Int
    var id: String { deck + status }
}

private struct MasteryChart: View {
    let decks: [Deck]

    private var rows: [MasteryRow] {
        decks.flatMap { deck -> [MasteryRow] in
            let cards = deck.activeCards
            let mastered = cards.filter(\.isMastered).count
            let fresh = cards.filter(\.isNew).count
            let learning = cards.count - mastered - fresh
            return [
                MasteryRow(deck: deck.name, status: "已熟悉", count: mastered),
                MasteryRow(deck: deck.name, status: "學習中", count: learning),
                MasteryRow(deck: deck.name, status: "新卡", count: fresh),
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(rows) { row in
                BarMark(
                    x: .value("張數", row.count),
                    y: .value("牌組", row.deck)
                )
                .foregroundStyle(by: .value("狀態", row.status))
            }
            .chartForegroundStyleScale([
                "已熟悉": Color.er.mastered,
                "學習中": Color.er.learning,
                "新卡": Color.er.fresh,
            ])
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .frame(height: CGFloat(decks.count) * 36 + 8)

            HStack(spacing: 14) {
                legend(Color.er.mastered, "已熟悉")
                legend(Color.er.learning, "學習中")
                legend(Color.er.fresh, "新卡")
            }
            .font(.caption)
            .foregroundStyle(Color.er.textSecondary)
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
