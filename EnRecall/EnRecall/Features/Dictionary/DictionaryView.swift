import SwiftUI
import SwiftData
import PhotosUI

/// 字典：一個大搜尋框，按「搜尋」才找單字、片語、句型（離線）。
/// 沒搜尋時下面放幾個推薦的字；搜尋框旁的相機拍課本、雜誌，找出裡面的片語和句型
struct DictionaryView: View {
    @Environment(\.modelContext) private var context

    @State private var query = ""
    /// 按下搜尋時的字；nil＝還沒搜尋（顯示推薦）
    @State private var searched: String?
    @State private var results = SearchResults()
    @State private var suggestions: [Card] = []
    @State private var selected: Card?
    @FocusState private var isFocused: Bool

    // 拍照找片語
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var scanImage: ScanImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                searchBar
                    .padding(.bottom, 8)
                if let searched {
                    resultList(for: searched)
                } else {
                    suggestionList
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .erPageBackground()
        .navigationTitle("字典")
        .task { if suggestions.isEmpty { loadSuggestions() } }
        .onChange(of: query) { _, value in
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                withAnimation(.spring(duration: 0.3)) { searched = nil }
            }
        }
        .sheet(item: $selected) { card in
            WordDetailSheet(card: card)
        }
        .sheet(item: $scanImage) { item in
            PhraseScanView(image: item.image)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { scanImage = ScanImage(image: image) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    scanImage = ScanImage(image: image)
                }
                photoItem = nil
            }
        }
    }

    // MARK: 搜尋框

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(Color.er.textTertiary)
                TextField("單字、片語、句型或中文", text: $query)
                    .font(.title3)
                    .foregroundStyle(Color.er.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isFocused)
                    .onSubmit(search)
                if !query.isEmpty {
                    Button {
                        query = ""
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.er.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除")
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(Color.er.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.er.outline))

            Menu {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        showCamera = true
                    } label: {
                        Label("拍照", systemImage: "camera")
                    }
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("從照片選", systemImage: "photo")
                }
            } label: {
                Image(systemName: "text.viewfinder")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.er.onPrimary)
                    .frame(width: 56, height: 56)
                    .background(Color.er.primary, in: Circle())
            }
            .accessibilityLabel("拍照找片語和句型")
        }
    }

    // MARK: 推薦

    @ViewBuilder
    private var suggestionList: some View {
        if !suggestions.isEmpty {
            HStack {
                SectionHeader(title: "推薦")
                Button {
                    withAnimation(.spring(duration: 0.3)) { loadSuggestions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.er.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("換一批")
            }
            cardList(suggestions)
        }
    }

    // MARK: 結果

    @ViewBuilder
    private func resultList(for searched: String) -> some View {
        if results.isEmpty {
            EmptyLine("找不到「\(searched)」")
        } else {
            if !results.words.isEmpty {
                SectionHeader(title: "單字", trailing: results.words.count.formatted())
                cardList(results.words)
            }
            if !results.phrases.isEmpty {
                SectionHeader(title: "片語", trailing: results.phrases.count.formatted())
                    .padding(.top, Theme.Spacing.sectionTop)
                cardList(results.phrases)
            }
            if !results.patterns.isEmpty {
                SectionHeader(title: "句型", trailing: results.patterns.count.formatted())
                    .padding(.top, Theme.Spacing.sectionTop)
                cardList(results.patterns)
            }
        }
    }

    private func cardList(_ cards: [Card]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if index > 0 {
                    Divider().overlay(Color.er.outline)
                }
                Button {
                    selected = card
                } label: {
                    WordRow(card: card, highlight: searched ?? "", showDeck: true)
                        .padding(.vertical, Theme.Spacing.row)
                }
                .buttonStyle(.plain)
            }
        }
        .erCard(elevated: true)
    }

    // MARK: 動作

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        results = DictionarySearch.search(text, in: context)
        withAnimation(.spring(duration: 0.3)) { searched = text }
    }

    private func loadSuggestions() {
        suggestions = DictionarySearch.suggestions(in: context)
    }
}

/// 拍的或選的照片（sheet 用）
struct ScanImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 搜尋結果分成單字、片語、句型
struct SearchResults {
    var words: [Card] = []
    var phrases: [Card] = []
    var patterns: [Card] = []

    var isEmpty: Bool { words.isEmpty && phrases.isEmpty && patterns.isEmpty }
}

enum DictionarySearch {
    static let limit = 200

    /// 英文比對字（開頭符合的排前面），也比對中文
    static func search(_ text: String, in context: ModelContext) -> SearchResults {
        let q = Normalizer.normalize(text)
        var descriptor = FetchDescriptor<Card>(predicate: #Predicate {
            $0.isRetired == false && ($0.wordNorm.localizedStandardContains(q) || $0.zh.localizedStandardContains(text))
        })
        descriptor.fetchLimit = limit
        let cards = (try? context.fetch(descriptor)) ?? []
        let sorted = cards.sorted { a, b in
            let aRank = rank(a, q)
            let bRank = rank(b, q)
            if aRank != bRank { return aRank < bRank }
            if a.wordNorm.count != b.wordNorm.count { return a.wordNorm.count < b.wordNorm.count }
            return a.wordNorm < b.wordNorm
        }
        var result = SearchResults()
        for card in sorted {
            if card.deck?.category == .pattern || card.pos == "句型" {
                result.patterns.append(card)
            } else if card.deck?.category == .phrase || card.word.contains(" ") {
                result.phrases.append(card)
            } else {
                result.words.append(card)
            }
        }
        return result
    }

    private static func rank(_ card: Card, _ q: String) -> Int {
        if card.wordNorm == q { return 0 }
        if card.wordNorm.hasPrefix(q) { return 1 }
        if card.wordNorm.contains(q) { return 2 }
        return 3
    }

    /// 推薦：最近忘記的字，再隨機補到 6 個
    static func suggestions(in context: ModelContext, count: Int = 6) -> [Card] {
        var forgotten = FetchDescriptor<Card>(
            predicate: #Predicate { $0.isRetired == false && $0.lapses > 0 },
            sortBy: [SortDescriptor(\.lastReview, order: .reverse)]
        )
        forgotten.fetchLimit = 12
        var picked = Array(((try? context.fetch(forgotten)) ?? []).shuffled().prefix(count / 2))

        let all = FetchDescriptor<Card>(predicate: #Predicate { $0.isRetired == false })
        let total = (try? context.fetchCount(all)) ?? 0
        var attempts = 0
        while picked.count < count, total > 0, attempts < count * 3 {
            attempts += 1
            var one = all
            one.fetchOffset = Int.random(in: 0..<total)
            one.fetchLimit = 1
            if let card = try? context.fetch(one).first, !picked.contains(where: { $0.id == card.id }) {
                picked.append(card)
            }
        }
        return picked
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
