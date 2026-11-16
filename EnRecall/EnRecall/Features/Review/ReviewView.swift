import SwiftUI
import SwiftData

/// 一輪複習。M3 先做畫面與流程：評分只會換下一張，FSRS 排程與存檔在 M4 接上
struct ReviewView: View {
    let session: ReviewSession

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]
    @Query private var logs: [ReviewLog]
    @AppStorage(SettingsKey.dailyNewLimit) private var dailyNewLimit = AppDefaults.dailyNewLimit

    @State private var queue: [Card] = []
    @State private var index = 0
    @State private var isRevealed = false
    @State private var isLoaded = false
    @State private var ratedCount = 0

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
                    FlashCardView(card: card, isFlipped: isRevealed)
                        .id(card.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                        .onTapGesture { reveal() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(isRevealed ? "" : "顯示答案")
                    Spacer(minLength: 0)
                    RatingBar(isRevealed: isRevealed, onReveal: reveal, onRate: rate)
                } else {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(Color.er.ratingGood)
                        Text("今天複習完了 · \(ratedCount) 張")
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
            }
            .navigationBarTitleDisplayMode(.inline)
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
        guard !isRevealed else { return }
        withAnimation(.spring(duration: 0.35)) { isRevealed = true }
    }

    private func rate(_ rating: Rating) {
        ratedCount += 1
        withAnimation(.spring(duration: 0.35)) {
            isRevealed = false
            index += 1
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
