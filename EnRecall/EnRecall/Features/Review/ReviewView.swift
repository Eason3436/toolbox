import SwiftUI
import SwiftData

/// 一輪複習：評分用 FSRS 排下次時間並存檔；學習中的卡（幾分鐘後再看）排回這一輪的最後面。
/// 可以復原上一張（卡片狀態和複習紀錄一起還原）
struct ReviewView: View {
    let session: ReviewSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]
    @Query private var logs: [ReviewLog]
    @AppStorage(SettingsKey.dailyNewLimit) private var dailyNewLimit = AppDefaults.dailyNewLimit

    @State private var queue: [Card] = []
    @State private var index = 0
    @State private var isRevealed = false
    @State private var isLoaded = false
    @State private var ratedCount = 0
    @State private var history: [Step] = []
    @State private var intervals: [Rating: String] = [:]
    @State private var detailCard: Card?

    private let scheduler = FSRSScheduler()

    /// 復原用：評分前的狀態
    private struct Step {
        let index: Int
        let card: Card
        let before: CardMemory
        let log: ReviewLog
        let requeued: Bool
    }

    private var current: Card? { queue.indices.contains(index) ? queue[index] : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if !isLoaded {
                    Spacer()
                } else if queue.isEmpty {
                    Spacer()
                    EmptyLine("沒有要複習的卡")
                    Spacer()
                } else if let card = current {
                    FlashCardView(card: card, isFlipped: isRevealed) { detailCard = card }
                        .id(card.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                        .onTapGesture { reveal() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(isRevealed ? "" : "顯示答案")
                    Spacer(minLength: 0)
                    RatingBar(isRevealed: isRevealed, intervals: intervals, onReveal: reveal, onRate: rate)
                } else {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(Color.er.ratingGood)
                        Text("今天複習完了 · \(Set(history.map(\.card.id)).count) 張")
                            .font(.headline)
                            .foregroundStyle(Color.er.text)
                        Button {
                            dismiss()
                        } label: {
                            Text("完成")
                                .font(.headline)
                                .foregroundStyle(Color.er.onPrimary)
                                .frame(minWidth: 120, minHeight: 36)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 8)
            .erPageBackground()
            .sensoryFeedback(.selection, trigger: ratedCount)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("關閉")
                }
                ToolbarItem(placement: .principal) {
                    if !queue.isEmpty {
                        ReviewProgress(done: min(index, queue.count), total: queue.count)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(history.isEmpty)
                    .accessibilityLabel("復原上一張")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $detailCard) { card in
            WordDetailSheet(card: card, showsProgress: false)
        }
        .task {
            guard !isLoaded else { return }
            loadQueue()
        }
    }

    private func loadQueue() {
        var source = decks
        if let deckID = session.deckID {
            source = source.filter { $0.id == deckID }
        }
        queue = StudyPlanner.queue(decks: source, logs: logs, globalNewLimit: dailyNewLimit, category: session.category)
        isLoaded = true
    }

    private func reveal() {
        guard !isRevealed, let card = current else { return }
        let now = Date()
        intervals = scheduler.preview(card.memory, now: now).mapValues { $0.intervalLabel(from: now) }
        withAnimation(.spring(duration: 0.35)) { isRevealed = true }
    }

    private func rate(_ rating: Rating) {
        guard let card = current else { return }
        let now = Date()
        let before = card.memory
        let outcome = scheduler.next(before, rating: rating, now: now)
        card.memory = outcome.memory

        let log = ReviewLog(
            cardId: card.id,
            deckId: card.deck?.id,
            rating: rating,
            stateBefore: before.state,
            reviewedAt: now,
            elapsedDays: outcome.elapsedDays,
            scheduledDays: outcome.scheduledDays
        )
        context.insert(log)
        try? context.save()

        // 還在學習步驟（幾分鐘後再看）：排回這一輪最後面
        let requeue = outcome.memory.state == .learning || outcome.memory.state == .relearning
        history.append(Step(index: index, card: card, before: before, log: log, requeued: requeue))
        ratedCount += 1
        withAnimation(.spring(duration: 0.35)) {
            if requeue { queue.append(card) }
            isRevealed = false
            index += 1
        }
    }

    private func undo() {
        guard let step = history.popLast() else { return }
        step.card.memory = step.before
        context.delete(step.log)
        try? context.save()
        withAnimation(.spring(duration: 0.35)) {
            if step.requeued, let last = queue.lastIndex(where: { $0.id == step.card.id }), last > step.index {
                queue.remove(at: last)
            }
            index = step.index
            isRevealed = false
        }
    }
}

private struct ReviewProgress: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .tint(Color.er.primary)
                .frame(width: 140)
            Text("\(done) / \(total)")
                .font(.erMono)
                .monospacedDigit()
                .foregroundStyle(Color.er.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("進度")
        .accessibilityValue("\(done) / \(total)")
    }
}

#Preview("淺色") {
    ReviewView(session: ReviewSession(category: nil))
        .previewEnvironment()
}

#Preview("深色") {
    ReviewView(session: ReviewSession(category: nil))
        .previewEnvironment()
        .preferredColorScheme(.dark)
}
