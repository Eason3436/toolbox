import SwiftUI
import SwiftData

/// 牌組頁的一張牌組卡：模式、進度、每天新卡
struct DeckCardView: View {
    @Bindable var deck: Deck
    /// 領新卡的順位（01、02…）
    let position: Int

    var body: some View {
        let cards = deck.activeCards
        let learned = cards.filter { !$0.isNew }.count
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: Route.deck(deck)) {
                HStack(spacing: Theme.Spacing.row) {
                    IconTile(label: deck.tileLabel, style: deck.kind == .custom ? .info : .muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deck.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.er.text)
                            .lineLimit(1)
                        Text("\(deck.category.countText(cards.count)) · \(deck.order.title)")
                            .font(.caption)
                            .foregroundStyle(Color.er.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Text(position, format: .number.precision(.integerLength(2)))
                        .font(.erMono)
                        .foregroundStyle(Color.er.textTertiary)
                        .accessibilityLabel("第 \(position) 順位")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(deck.isPaused ? 0.55 : 1)

            HStack(spacing: 10) {
                Picker("模式", selection: $deck.runMode) {
                    ForEach(DeckMode.running) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(deck.isPaused)

                Button {
                    withAnimation(.spring(duration: 0.25)) { deck.isPaused.toggle() }
                } label: {
                    Image(systemName: deck.isPaused ? "play.fill" : "pause.fill")
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(deck.isPaused ? Color.er.primary : Color.er.textSecondary)
                .sensoryFeedback(.selection, trigger: deck.isPaused)
                .accessibilityLabel(deck.isPaused ? "繼續" : "暫停")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("已背")
                        .foregroundStyle(Color.er.textSecondary)
                    Spacer()
                    Text("\(learned.formatted()) / \(cards.count.formatted())")
                        .monospacedDigit()
                        .foregroundStyle(Color.er.text)
                }
                .font(.caption)
                LinearMeter(value: cards.isEmpty ? 0 : Double(learned) / Double(cards.count))
            }
            .opacity(deck.isPaused ? 0.55 : 1)

            Stepper(value: $deck.dailyNewLimit, in: 0...100) {
                HStack {
                    Text("每天新卡")
                        .foregroundStyle(Color.er.textSecondary)
                    Spacer()
                    Text(deck.dailyNewLimit, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(Color.er.text)
                }
                .font(.subheadline)
            }
            .disabled(deck.mode != .active)
        }
        .erCard(padding: Theme.Spacing.cardLarge, elevated: true)
        .animation(.spring(duration: 0.25), value: deck.mode)
    }
}

#Preview("淺色") {
    let container = PreviewData.container
    let decks = (try? container.mainContext.fetch(FetchDescriptor<Deck>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    NavigationStack {
        ScrollView {
            VStack(spacing: Theme.Spacing.stack) {
                ForEach(Array(decks.enumerated()), id: \.element.id) { offset, deck in
                    DeckCardView(deck: deck, position: offset + 1)
                }
            }
            .padding(Theme.Spacing.page)
        }
        .erPageBackground()
    }
    .previewEnvironment()
}

#Preview("深色") {
    let container = PreviewData.container
    let deck = (try? container.mainContext.fetch(FetchDescriptor<Deck>()))?.first { $0.id == "gsat-4" }
    NavigationStack {
        if let deck {
            DeckCardView(deck: deck, position: 1)
                .padding(Theme.Spacing.page)
                .frame(maxHeight: .infinity, alignment: .top)
                .erPageBackground()
        }
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
