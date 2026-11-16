import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]
    @Query(sort: \ReviewLog.reviewedAt, order: .reverse) private var logs: [ReviewLog]
    @AppStorage(SettingsKey.dailyNewLimit) private var dailyNewLimit = AppDefaults.dailyNewLimit
    @Environment(StoreModel.self) private var store
    @State private var session: ReviewSession?

    private var summary: StudySummary {
        StudyPlanner.summary(decks: decks, logs: logs, globalNewLimit: dailyNewLimit)
    }

    private var latestClaudeDeck: Deck? {
        decks.filter { $0.kind == .custom }.max { ($0.lastImportedAt ?? $0.createdAt) < ($1.lastImportedAt ?? $1.createdAt) }
    }

    var body: some View {
        let summary = summary
        let streak = StatsCalculator.streak(logs)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                HStack {
                    Text(Date.now, format: .dateTime.month().day().weekday(.wide))
                        .font(.subheadline)
                        .foregroundStyle(Color.er.textSecondary)
                    Spacer()
                    if streak > 0 {
                        Chip(text: "連續 \(streak) 天", systemImage: "flame")
                    }
                }

                TodayHeroCard(summary: summary) {
                    session = ReviewSession(category: nil)
                }

                SectionHeader(title: "練習模式")
                VStack(spacing: 0) {
                    ForEach(DeckCategory.allCases) { category in
                        PracticeRow(category: category, counts: summary.counts(for: category)) {
                            session = ReviewSession(category: category)
                        }
                        if category != DeckCategory.allCases.last {
                            Divider().overlay(Color.er.outline).padding(.leading, 64)
                        }
                    }
                }
                .erCard(padding: 0, elevated: true)

                if let deck = latestClaudeDeck {
                    SectionHeader(title: "從 Claude 匯入")
                    NavigationLink(value: Route.deck(deck)) {
                        ClaudeDeckRow(deck: deck)
                    }
                    .buttonStyle(.plain)
                }

                SectionHeader(title: "單字")
                NavigationLink(value: Route.store) {
                    StoreRow(updates: store.updatesAvailable(decks: decks).count)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 24)
        }
        .erPageBackground()
        .navigationTitle("今天")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.store) {
                    Image(systemName: "bag")
                }
                .accessibilityLabel("單字商店")
            }
        }
        .fullScreenCover(item: $session) { session in
            ReviewView(session: session)
        }
    }
}

// MARK: - 今日複習主卡

private struct TodayHeroCard: View {
    let summary: StudySummary
    let start: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日複習")
                    .font(.erLabel)
                    .tracking(1.1)
                    .foregroundStyle(Color.er.heroTextSecondary)
                Spacer()
                Chip(text: "新卡 \(summary.all.new)", style: .hero)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(summary.all.due, format: .number)
                    .numberFont(48, relativeTo: .largeTitle, weight: .bold)
                    .foregroundStyle(Color.er.heroText)
                    .contentTransition(.numericText(value: Double(summary.all.due)))
                Text("張到期")
                    .font(.subheadline)
                    .foregroundStyle(Color.er.heroTextSecondary)
            }
            .accessibilityElement(children: .combine)

            DistributionBar(summary: summary)

            Button(action: start) {
                Text("開始複習")
                    .font(.headline)
                    .foregroundStyle(Color.er.hero)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.er.heroText)
            .disabled(summary.all.total == 0)
        }
        .padding(Theme.Spacing.cardLarge)
        .background(Color.er.hero, in: shape)
        .overlay(shape.strokeBorder(Color.er.heroOutline, lineWidth: 1))
    }
}

/// 記憶卡／片語記憶卡的比例條
private struct DistributionBar: View {
    let summary: StudySummary

    var body: some View {
        let word = summary.counts(for: .word).total
        let phrase = summary.counts(for: .phrase).total
        let total = max(word + phrase, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 3) {
                    Capsule()
                        .fill(Color.er.heroText)
                        .frame(width: max(0, proxy.size.width - 3) * CGFloat(word) / CGFloat(total))
                    Capsule()
                        .fill(Color.er.heroMuted)
                }
            }
            .frame(height: 6)
            HStack(spacing: 14) {
                legend(color: Color.er.heroText, title: "記憶卡", value: word)
                legend(color: Color.er.heroMuted, title: "片語記憶卡", value: phrase)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(color: Color, title: String, value: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(Color.er.heroTextSecondary)
            Text(value, format: .number)
                .foregroundStyle(Color.er.heroText)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

// MARK: - 列

private struct PracticeRow: View {
    let category: DeckCategory
    let counts: StudyCounts
    let start: () -> Void

    private var title: String { category == .word ? "記憶卡" : "片語記憶卡" }

    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            IconTile(label: category == .word ? "Aa" : "Ph")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                Text("到期 \(counts.due) · 新卡 \(counts.new)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.er.textSecondary)
            }
            Spacer(minLength: 8)
            Button("開始", action: start)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(counts.total == 0)
        }
        .padding(Theme.Spacing.card)
    }
}

private struct ClaudeDeckRow: View {
    let deck: Deck

    var body: some View {
        let newCount = deck.activeCards.filter(\.isNew).count
        HStack(spacing: Theme.Spacing.row) {
            IconTile(label: deck.tileLabel, style: .info)
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                Text("從 Claude 匯入 · \(newCount) 張新卡")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.er.textSecondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.er.textTertiary)
        }
        .erCard(elevated: true)
    }
}

private struct StoreRow: View {
    let updates: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(Color.er.fill)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "bag")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.er.text)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("單字商店")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                if updates > 0 {
                    HStack(spacing: 6) {
                        Circle().fill(Color.er.accent).frame(width: 6, height: 6)
                        Text("\(updates) 包有新版")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.er.info)
                } else {
                    Text("學測 Level 1–6 · 片語")
                        .font(.caption)
                        .foregroundStyle(Color.er.textSecondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.er.textTertiary)
        }
        .erCard(elevated: true)
    }
}

#Preview("淺色") {
    NavigationStack {
        HomeView().appDestinations()
    }
    .previewEnvironment()
}

#Preview("深色") {
    NavigationStack {
        HomeView().appDestinations()
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
