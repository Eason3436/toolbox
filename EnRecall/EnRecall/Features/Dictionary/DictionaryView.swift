import SwiftUI
import SwiftData

/// 查本機所有牌組裡的字（離線）
struct DictionaryView: View {
    @Query(sort: \Card.wordNorm) private var cards: [Card]
    @State private var query = ""
    @State private var selected: Card?

    private var results: [Card] {
        let q = Normalizer.normalize(query)
        let active = cards.filter { !$0.isRetired }
        guard !q.isEmpty else { return active }
        // 開頭符合的排前面，再來是中文或中間符合的
        let prefix = active.filter { $0.wordNorm.hasPrefix(q) }
        let prefixIDs = Set(prefix.map(\.id))
        let other = active.filter { !prefixIDs.contains($0.id) && ($0.wordNorm.contains(q) || $0.zh.contains(query)) }
        return prefix + other
    }

    var body: some View {
        let results = results
        List {
            if cards.isEmpty {
                EmptyLine("還沒有單字")
                    .listRowBackground(Color.clear)
            } else if results.isEmpty {
                EmptyLine("沒有符合的單字")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(results) { card in
                        Button {
                            selected = card
                        } label: {
                            WordRow(card: card, highlight: query, showDeck: true)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.er.surface)
                    }
                } header: {
                    Text("\(results.count.formatted()) 個\(query.isEmpty ? "單字" : "結果")")
                        .font(.erLabel)
                        .foregroundStyle(Color.er.textTertiary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .erPageBackground()
        .navigationTitle("字典")
        .searchable(text: $query, prompt: "搜尋英文或中文")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .sheet(item: $selected) { card in
            WordDetailSheet(card: card)
        }
    }
}

/// 單字詳細（字典、牌組詳細頁共用）
struct WordDetailSheet: View {
    let card: Card
    @Environment(\.dismiss) private var dismiss

    private var metaLine: String {
        [card.phonetic, card.pos].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.word)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color.er.text)
                            .minimumScaleFactor(0.6)
                        if !metaLine.isEmpty {
                            Text(metaLine)
                                .font(.erMono)
                                .foregroundStyle(Color.er.textSecondary)
                        }
                    }
                    Spacer(minLength: 8)
                    SpeakButton(text: card.word, size: 44)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.er.textSecondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("關閉")
                }

                Text(card.zh)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.er.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                if let example = card.example, !example.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("例句")
                                .font(.erLabel)
                                .tracking(1.1)
                                .foregroundStyle(Color.er.textTertiary)
                            if card.source == .claude {
                                Chip(text: "AI 例句", style: .info)
                            }
                        }
                        Text(example)
                            .font(.body)
                            .foregroundStyle(Color.er.text)
                        if let zh = card.exampleZh, !zh.isEmpty {
                            Text(zh)
                                .font(.subheadline)
                                .foregroundStyle(Color.er.textSecondary)
                        }
                    }
                    .erCard()
                }

                Grid(horizontalSpacing: Theme.Spacing.stack) {
                    GridRow {
                        infoCell(title: "下次複習", value: nextReviewText)
                        infoCell(title: "已複習", value: "\(card.reps) 次")
                        infoCell(title: "牌組", value: card.deck?.name ?? "—")
                    }
                }
            }
            .padding(Theme.Spacing.page)
        }
        .erPageBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var nextReviewText: String {
        if card.isNew { return "新卡" }
        return card.due.formatted(.relative(presentation: .named))
    }

    private func infoCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.er.textTertiary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.er.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .erCard(padding: Theme.Spacing.row)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview("淺色") {
    NavigationStack {
        DictionaryView()
    }
    .previewEnvironment()
}

#Preview("深色") {
    NavigationStack {
        DictionaryView()
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}

#Preview("單字 · 淺色") {
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.word == "accommodate" }
    if let card {
        WordDetailSheet(card: card)
            .modelContainer(container)
    }
}

#Preview("單字 · 深色") {
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.source == .claude }
    if let card {
        WordDetailSheet(card: card)
            .modelContainer(container)
            .preferredColorScheme(.dark)
    }
}

#Preview("空 · 淺色") {
    NavigationStack {
        DictionaryView()
    }
    .previewEnvironment(empty: true)
}
