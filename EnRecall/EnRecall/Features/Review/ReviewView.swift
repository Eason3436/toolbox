import SwiftUI
import SwiftData

/// 一輪複習：評分用 FSRS 排下次時間；學習中的卡（幾分鐘後再看）排回這一輪的最後面。
/// - 上方時間軸：前面評過的字（顏色＝當時選的記憶程度），可以左右滑、點回去看或改評分；後面標出新字／複習
/// - 右上可以復原上一張
/// - 複習用自己的 ModelContext，關掉、切到背景時才存：首頁、牌組那些統計不會每評一張就重算一次（之前會頓）
struct ReviewView: View {
    let session: ReviewSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var mainContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.dailyNewLimit) private var dailyNewLimit = AppDefaults.dailyNewLimit
    @AppStorage(SettingsKey.reviewMix) private var mix: ReviewMix = .mixed

    @State private var context: ModelContext?
    @State private var plan = StudyPlanner.Plan()
    @State private var queue: [Card] = []
    @State private var index = 0
    @State private var isRevealed = false
    @State private var isLoaded = false
    @State private var ratedCount = 0
    @State private var history: [Step] = []
    @State private var intervals: [Rating: String] = [:]
    /// 回頭看第幾張（history 的位置）；nil＝目前這張
    @State private var viewing: Int?
    @State private var viewingIntervals: [Rating: String] = [:]
    @State private var details = DetailCache()

    private let scheduler = FSRSScheduler()

    /// 評過的一張：復原、改評分用
    struct Step {
        let index: Int
        let card: Card
        let before: CardMemory
        let log: ReviewLog
        var requeued: Bool
    }

    private var current: Card? { queue.indices.contains(index) ? queue[index] : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if isLoaded {
                    ReviewTimeline(
                        history: history,
                        upcoming: Array(queue.dropFirst(index)),
                        viewing: viewing,
                        onSelect: select
                    )
                    content
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 8)
            .erPageBackground()
            .sensoryFeedback(.selection, trigger: ratedCount)
            .toolbar { toolbar }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            guard !isLoaded else { return }
            load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { save() }
        }
        .onDisappear { save() }
        .onChange(of: mix) {
            guard isLoaded else { return }
            rebuildUpcoming()
        }
    }

    // MARK: 畫面

    @ViewBuilder
    private var content: some View {
        if let viewing, history.indices.contains(viewing) {
            let step = history[viewing]
            FlashCardView(card: step.card, detail: details.detail(for: step.card, in: context), isFlipped: true)
                .id("past-\(viewing)")
                .transition(.opacity)
            Spacer(minLength: 0)
            Button {
                withAnimation(.spring(duration: 0.3)) { self.viewing = nil }
            } label: {
                Label("回到目前這張", systemImage: "arrow.uturn.forward")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
            RatingBar(
                isRevealed: true,
                intervals: viewingIntervals,
                selected: Rating(rawValue: step.log.rating),
                isLocked: !canRerate(viewing),
                onReveal: {},
                onRate: { rerate(viewing, to: $0) }
            )
        } else if queue.isEmpty {
            Spacer()
            EmptyLine(emptyText)
            Spacer()
        } else if let card = current {
            FlashCardView(card: card, detail: details.detail(for: card, in: context), isFlipped: isRevealed)
                .id("\(index)-\(card.id)")
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
            finished
        }
    }

    private var emptyText: String {
        switch mix {
        case .mixed: "沒有要複習的卡"
        case .newOnly: "今天沒有新字了"
        case .reviewOnly: "沒有要複習的卡"
        }
    }

    private var finished: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color.er.ratingGood)
            Text("今天複習完了 · \(Set(history.map(\.card.id)).count) 張")
                .font(.headline)
                .foregroundStyle(Color.er.text)
            Button {
                close()
            } label: {
                Text("完成")
                    .font(.headline)
                    .foregroundStyle(Color.er.onPrimary)
                    .frame(minWidth: 120, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            Spacer()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("關閉")
        }
        ToolbarItem(placement: .principal) {
            if isLoaded {
                Menu {
                    Picker("接下來", selection: $mix) {
                        ForEach(ReviewMix.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(mix.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.er.text)
                        Text("\(min(index, queue.count).formatted()) / \(queue.count.formatted())")
                            .font(.erMono)
                            .monospacedDigit()
                            .foregroundStyle(Color.er.textSecondary)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.er.textSecondary)
                    }
                    .padding(.horizontal, 6)
                }
                .accessibilityLabel("接下來：\(mix.title)，\(min(index, queue.count)) / \(queue.count)")
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

    // MARK: 載入、存檔

    private func load() {
        let reviewContext = ModelContext(mainContext.container)
        reviewContext.autosaveEnabled = false
        context = reviewContext

        var decks = (try? reviewContext.fetch(FetchDescriptor<Deck>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        if let deckID = session.deckID {
            decks = decks.filter { $0.id == deckID }
        }
        let start = Calendar.current.startOfDay(for: Date())
        let todayLogs = (try? reviewContext.fetch(FetchDescriptor<ReviewLog>(predicate: #Predicate { $0.reviewedAt >= start }))) ?? []
        var plan = StudyPlanner.plan(decks: decks, logs: todayLogs, globalNewLimit: dailyNewLimit)
        if let category = session.category {
            plan.due = plan.due.filter { $0.deck?.category == category }
            plan.new = plan.new.filter { $0.deck?.category == category }
        }
        self.plan = plan
        queue = StudyPlanner.arrange(due: plan.due, new: plan.new, mix: mix)
        isLoaded = true
    }

    private func save() {
        guard let context, context.hasChanges else { return }
        try? context.save()
    }

    private func close() {
        save()
        dismiss()
    }

    /// 換「混合／新字／複習」：還沒出現的卡重排，已經看過的不動
    private func rebuildUpcoming() {
        let shownIDs = Set(queue.prefix(index).map(\.id))
        let requeued = queue.dropFirst(index).filter { shownIDs.contains($0.id) }
        let fresh = StudyPlanner.arrange(due: plan.due, new: plan.new, mix: mix).filter { !shownIDs.contains($0.id) }
        withAnimation(.spring(duration: 0.35)) {
            queue = Array(queue.prefix(index)) + fresh + requeued
            isRevealed = false
            viewing = nil
        }
    }

    // MARK: 評分

    private func reveal() {
        guard !isRevealed, let card = current else { return }
        let now = Date()
        intervals = scheduler.preview(card.memory, now: now).mapValues { $0.intervalLabel(from: now) }
        withAnimation(.spring(duration: 0.35)) { isRevealed = true }
    }

    private func rate(_ rating: Rating) {
        guard let card = current, let context else { return }
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

        // 還在學習步驟（幾分鐘後再看）：排回這一輪最後面
        let requeue = outcome.memory.state.isLearning
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
        context?.delete(step.log)
        withAnimation(.spring(duration: 0.35)) {
            if step.requeued, let last = queue.lastIndex(where: { $0.id == step.card.id }), last > step.index {
                queue.remove(at: last)
            }
            index = step.index
            isRevealed = false
            viewing = nil
        }
    }

    // MARK: 回頭看、改評分

    private func select(_ position: Int?) {
        if let position, history.indices.contains(position) {
            let step = history[position]
            let at = step.log.reviewedAt
            viewingIntervals = scheduler.preview(step.before, now: at).mapValues { $0.intervalLabel(from: at) }
        }
        withAnimation(.spring(duration: 0.3)) { viewing = position }
    }

    /// 同一張卡後面又評過一次，就不能回頭改（後面的排程是接著這次算的）
    private func canRerate(_ position: Int) -> Bool {
        let id = history[position].card.id
        return !history.dropFirst(position + 1).contains { $0.card.id == id }
    }

    private func rerate(_ position: Int, to rating: Rating) {
        var step = history[position]
        guard rating.rawValue != step.log.rating, canRerate(position) else {
            withAnimation(.spring(duration: 0.3)) { viewing = nil }
            return
        }
        let at = step.log.reviewedAt
        let outcome = scheduler.next(step.before, rating: rating, now: at)
        step.card.memory = outcome.memory
        step.log.rating = rating.rawValue
        step.log.scheduledDays = outcome.scheduledDays
        let requeue = outcome.memory.state.isLearning
        ratedCount += 1
        withAnimation(.spring(duration: 0.35)) {
            if step.requeued, !requeue,
               let copy = queue.lastIndex(where: { $0.id == step.card.id }), copy >= index {
                queue.remove(at: copy)
                if copy == index { isRevealed = false }
            }
            if !step.requeued, requeue {
                queue.append(step.card)
            }
            step.requeued = requeue
            history[position] = step
            viewing = nil
        }
    }
}

private extension FSRSState {
    var isLearning: Bool { self == .learning || self == .relearning }
}

/// 複習卡的完整內容：同一張只讀一次
@MainActor
final class DetailCache {
    private var store: [String: CardDetail?] = [:]

    func detail(for card: Card, in context: ModelContext?) -> CardDetail? {
        if let cached = store[card.id] { return cached }
        guard let context else { return nil }
        let detail = CardDetail.load(for: card.id, in: context)
        store[card.id] = .some(detail)
        return detail
    }
}

// MARK: - 上方時間軸

/// 前面評過的字（記憶程度的顏色）→ 目前這張 → 後面的新字／複習。可以左右滑，點前面的字回頭看
struct ReviewTimeline: View {
    let history: [ReviewView.Step]
    let upcoming: [Card]
    let viewing: Int?
    let onSelect: (Int?) -> Void

    private static let upcomingLimit = 40

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(history.enumerated()), id: \.offset) { position, step in
                        pastChip(position: position, step: step)
                            .id("past-\(position)")
                    }
                    ForEach(Array(upcoming.prefix(Self.upcomingLimit).enumerated()), id: \.offset) { offset, card in
                        upcomingChip(card: card, isCurrent: offset == 0)
                            .id(offset == 0 ? "current" : "next-\(offset)")
                    }
                    if upcoming.count > Self.upcomingLimit {
                        Text("+\((upcoming.count - Self.upcomingLimit).formatted())")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.er.textTertiary)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .frame(height: 36)
            .onAppear { proxy.scrollTo("current", anchor: .center) }
            .onChange(of: history.count) {
                withAnimation(.spring(duration: 0.35)) { proxy.scrollTo("current", anchor: .center) }
            }
            .onChange(of: viewing) { _, value in
                withAnimation(.spring(duration: 0.35)) {
                    proxy.scrollTo(value.map { "past-\($0)" } ?? "current", anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("這一輪的卡")
    }

    private func pastChip(position: Int, step: ReviewView.Step) -> some View {
        let rating = Rating(rawValue: step.log.rating) ?? .good
        let isViewing = viewing == position
        return Button {
            onSelect(isViewing ? nil : position)
        } label: {
            Text(step.card.word)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(rating.color)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(rating.color.opacity(isViewing ? 0.3 : 0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(rating.color, lineWidth: isViewing ? 1.5 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(step.card.word)，\(rating.title)")
        .accessibilityAddTraits(isViewing ? .isSelected : [])
    }

    private func upcomingChip(card: Card, isCurrent: Bool) -> some View {
        let label = card.isNew ? "新字" : (card.state == .review ? "複習" : "再一次")
        let tint = card.isNew ? Color.er.info : Color.er.textSecondary
        return Button {
            onSelect(nil)
        } label: {
            Text(label)
                .font(.caption.weight(isCurrent ? .semibold : .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .frame(height: isCurrent ? 30 : 26)
                .background(card.isNew ? Color.er.infoContainer : Color.er.fill, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.er.primary, lineWidth: isCurrent && viewing == nil ? 1.5 : 0))
        }
        .buttonStyle(.plain)
        .disabled(!isCurrent)
        .accessibilityLabel(isCurrent ? "目前：\(label)" : label)
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
