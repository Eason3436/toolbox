import SwiftUI
import SwiftData

/// 牌組裡的單字列表
struct DeckDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var deck: Deck
    @State private var query = ""
    @State private var session: ReviewSession?
    @State private var selected: Card?

    private var cards: [Card] {
        let all = deck.orderedActiveCards
        let q = Normalizer.normalize(query)
        guard !q.isEmpty else { return all }
        return all.filter { $0.wordNorm.contains(q) || $0.zh.contains(query) }
    }

    var body: some View {
        let cards = cards
        List {
            if cards.isEmpty {
                EmptyLine(query.isEmpty ? "還沒有單字" : "沒有符合的單字")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(cards) { card in
                        Button {
                            selected = card
                        } label: {
                            WordRow(card: card)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.er.surface)
                        .swipeActions(edge: .trailing) {
                            // 連過來的字才能移出；卡片和進度還在原本的牌組
                            if deck.isLinked(card) {
                                Button("移出牌組", systemImage: "minus.circle", role: .destructive) {
                                    remove(card)
                                }
                            }
                        }
                    }
                } header: {
                    Text("\(cards.count.formatted()) 個")
                        .font(.erLabel)
                        .foregroundStyle(Color.er.textTertiary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .erPageBackground()
        .navigationTitle(deck.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜尋單字")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("新卡順序", selection: $deck.order) {
                        ForEach(NewCardOrder.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("新卡順序")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("複習", systemImage: "play.fill") {
                    session = ReviewSession(category: nil, deckID: deck.id)
                }
            }
        }
        .sheet(item: $selected) { card in
            WordDetailSheet(card: card)
        }
        .fullScreenCover(item: $session) { session in
            ReviewView(session: session)
        }
    }

    private func remove(_ card: Card) {
        withAnimation(.spring(duration: 0.3)) {
            if DeckMembership.remove(card, from: deck, in: context) {
                try? context.save()
            }
        }
    }
}

/// 單字列（牌組詳細頁、字典共用）
struct WordRow: View {
    let card: Card
    /// 字典搜尋時要加粗的開頭
    var highlight: String = ""
    var showDeck = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    wordText
                        .font(.body)
                        .foregroundStyle(Color.er.text)
                    if let pos = card.pos, !pos.isEmpty {
                        Text(pos)
                            .font(.erMonoSmall)
                            .foregroundStyle(Color.er.textTertiary)
                            .lineLimit(1)
                    }
                }
                Text(card.zh.replacingOccurrences(of: "\n", with: "；"))
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if showDeck, let deck = card.deck {
                Text(deck.tileLabel)
                    .font(.erMonoSmall)
                    .foregroundStyle(Color.er.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var wordText: Text {
        let word = card.word
        let count = highlight.count
        guard count > 0, card.wordNorm.hasPrefix(Normalizer.normalize(highlight)), word.count >= count else {
            return Text(word)
        }
        let head = String(word.prefix(count))
        let tail = String(word.dropFirst(count))
        return Text("\(Text(head).fontWeight(.bold))\(tail)")
    }
}

#Preview("淺色") {
    let container = PreviewData.container
    let deck = (try? container.mainContext.fetch(FetchDescriptor<Deck>()))?.first { $0.id == "gsat-4" }
    NavigationStack {
        if let deck { DeckDetailView(deck: deck) }
    }
    .previewEnvironment()
}

#Preview("深色") {
    let container = PreviewData.container
    let deck = (try? container.mainContext.fetch(FetchDescriptor<Deck>()))?.first { $0.id == "custom:preview" }
    NavigationStack {
        if let deck { DeckDetailView(deck: deck) }
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
