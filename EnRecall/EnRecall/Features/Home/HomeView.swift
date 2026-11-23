import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]
    /// 只讀今天的複習紀錄（今天的數字用）；連續天數用共用的每日張數
    @Query private var logs: [ReviewLog]
    @AppStorage(SettingsKey.dailyNewLimit) private var dailyNewLimit = AppDefaults.dailyNewLimit
    @Environment(StoreModel.self) private var store
    @State private var session: ReviewSession?
    @Environment(StudySummaryCache.self) private var studyCache
    @State private var isQuizzing = false
    @State private var isPickingHandout = false
    @State private var isMakingHandout = false
    @State private var handoutURL: URL?
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts

    private var summary: StudySummary {
        studyCache.summary(decks: decks, logs: logs, globalNewLimit: dailyNewLimit)
    }

    /// 句型卡要有句型牌組才出現在練習模式
    private var practiceCategories: [DeckCategory] {
        DeckCategory.allCases.filter { $0 != .pattern || decks.contains { $0.category == .pattern } }
    }

    /// 最近加入的自訂牌組（跟其他牌組一樣顯示，不特別標來源）
    private var latestCustomDeck: Deck? {
        decks.filter { $0.kind == .custom }.max { ($0.lastImportedAt ?? $0.createdAt) < ($1.lastImportedAt ?? $1.createdAt) }
    }

    init() {
        let start = Calendar.current.startOfDay(for: Date())
        _logs = Query(filter: #Predicate<ReviewLog> { $0.reviewedAt >= start })
    }

    var body: some View {
        let summary = summary
        let streak = studyCache.logDigest(context: context).streak()
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
                    ForEach(practiceCategories) { category in
                        PracticeRow(category: category, counts: summary.counts(for: category)) {
                            session = ReviewSession(category: category)
                        }
                        Divider().overlay(Color.er.outline).padding(.leading, 64)
                    }
                    QuizRow {
                        isQuizzing = true
                    }
                    Divider().overlay(Color.er.outline).padding(.leading, 64)
                    HandoutRow(isMaking: isMakingHandout, open: { isPickingHandout = true }, make: makeHandout)
                }
                .erCard(padding: 0, elevated: true)

                if let deck = latestCustomDeck {
                    SectionHeader(title: "最近加入")
                    NavigationLink(value: Route.deck(deck)) {
                        RecentDeckRow(deck: deck)
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
        .fullScreenCover(isPresented: $isQuizzing) {
            QuizView()
        }
        .sheet(isPresented: $isPickingHandout) {
            HandoutView()
        }
        .quickLookPreview($handoutURL)
    }

    /// 一鍵：照上次的設定做 PDF，做好直接預覽（可以分享、列印）
    private func makeHandout() {
        guard !isMakingHandout else { return }
        isMakingHandout = true
        Task {
            do {
                handoutURL = try await HandoutMaker.make(.saved, context: context)
            } catch {
                toasts.show(error.localizedDescription, systemImage: "doc")
            }
            isMakingHandout = false
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

    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            IconTile(label: category.tileLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.practiceTitle)
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

/// 測驗：中翻英、英文填空、片語填空
private struct QuizRow: View {
    let start: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            IconTile(label: "Qz")
            VStack(alignment: .leading, spacing: 2) {
                Text("測驗")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                Text("中翻英 · 英文填空 · 片語填空")
                    .font(.caption)
                    .foregroundStyle(Color.er.textSecondary)
            }
            Spacer(minLength: 8)
            Button("開始", action: start)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .padding(Theme.Spacing.card)
    }
}

/// 單字 PDF：按「產生」照上次的設定一鍵做好；點這一列改設定
private struct HandoutRow: View {
    let isMaking: Bool
    let open: () -> Void
    let make: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            Button(action: open) {
                HStack(spacing: Theme.Spacing.row) {
                    IconTile(label: "PDF")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("單字 PDF")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.er.text)
                        Text(HandoutOptions.saved.summary)
                            .font(.caption)
                            .foregroundStyle(Color.er.textSecondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("改 PDF 的用途、範圍、字數")

            Button(action: make) {
                if isMaking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("產生")
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(isMaking)
        }
        .padding(Theme.Spacing.card)
    }
}

private struct RecentDeckRow: View {
    let deck: Deck

    var body: some View {
        let cards = deck.activeCards
        let newCount = cards.filter(\.isNew).count
        HStack(spacing: Theme.Spacing.row) {
            IconTile(label: deck.tileLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                Text("\(deck.category.countText(cards.count)) · 新卡 \(newCount)")
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
