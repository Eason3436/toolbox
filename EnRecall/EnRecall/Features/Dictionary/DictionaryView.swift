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

#Preview("空 · 淺色") {
    NavigationStack {
        DictionaryView()
    }
    .previewEnvironment(empty: true)
}
