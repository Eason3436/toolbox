import SwiftUI
import SwiftData

/// 複習卡背面的分頁：只列出這個字有內容的
enum DetailTab: String, Identifiable, Hashable {
    case examples
    case collocations
    case patterns
    case phrases
    case synonyms
    case antonyms
    case confusables
    case similar
    case errors
    case origin
    case related
    case usage
    case mix
    case years
    // 句型卡
    case structure
    case variations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .examples: "例句"
        case .collocations: "搭配"
        case .patterns: "句型"
        case .phrases: "片語"
        case .synonyms: "近義字"
        case .antonyms: "反義字"
        case .confusables: "易混淆"
        case .similar: "比較"
        case .errors: "常見錯誤"
        case .origin: "字源"
        case .related: "同字根"
        case .usage: "用法"
        case .mix: "易混淆"
        case .years: "考過"
        case .structure: "結構"
        case .variations: "變化"
        }
    }

    /// 沒有完整內容（從 Claude 寫的字）就是空的，卡片照舊只顯示一句例句
    static func available(for detail: CardDetail?) -> [DetailTab] {
        if let pattern = detail?.pattern {
            var tabs: [DetailTab] = []
            if !pattern.slots.isEmpty { tabs.append(.structure) }
            if !pattern.examples.isEmpty { tabs.append(.examples) }
            if pattern.explanation != nil || pattern.tips != nil || pattern.register != nil { tabs.append(.usage) }
            if !pattern.variations.isEmpty { tabs.append(.variations) }
            if !pattern.collocations.isEmpty { tabs.append(.collocations) }
            if !pattern.similar.isEmpty { tabs.append(.similar) }
            if !pattern.errors.isEmpty { tabs.append(.errors) }
            return tabs
        }
        if let word = detail?.word {
            var tabs: [DetailTab] = [.examples]
            if !word.allCollocations.isEmpty { tabs.append(.collocations) }
            if word.meanings.contains(where: { !$0.patterns.isEmpty }) { tabs.append(.patterns) }
            if !word.phrases.isEmpty { tabs.append(.phrases) }
            if !word.otherSynonyms.isEmpty { tabs.append(.synonyms) }
            if !word.antonyms.isEmpty { tabs.append(.antonyms) }
            if !word.confusables.isEmpty { tabs.append(.confusables) }
            if !(detail?.similar ?? []).isEmpty { tabs.append(.similar) }
            if !word.commonErrors.isEmpty { tabs.append(.errors) }
            if !word.breakdown.isEmpty || word.origin != nil { tabs.append(.origin) }
            if !word.related.isEmpty { tabs.append(.related) }
            return tabs
        }
        if let phrase = detail?.phrase {
            var tabs: [DetailTab] = [.examples]
            if phrase.use != nil { tabs.append(.usage) }
            if phrase.mix != nil { tabs.append(.mix) }
            if phrase.yearList.count > 0 { tabs.append(.years) }
            return tabs
        }
        return []
    }
}

extension WordDetail {
    /// 近義字裡拿掉單字自己
    var otherSynonyms: [Synonym] {
        synonyms.filter { $0.word.lowercased() != word.lowercased() }
    }
}

extension PhraseDetail {
    /// 「103 105 106」→ ["103", "105", "106"]
    var yearList: [String] {
        (years ?? "").split(separator: " ").map(String.init)
    }
}

// MARK: - 分頁列

struct DetailTabBar: View {
    let tabs: [DetailTab]
    @Binding var selection: DetailTab

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    let isSelected = tab == selection
                    Button {
                        selection = tab
                    } label: {
                        Text(tab.title)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.er.onPrimary : Color.er.textSecondary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(isSelected ? Color.er.primary : Color.er.fill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .softScrollEdges(.horizontal, length: 18)
        .scrollEdgeEffectHidden(true, for: .all)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - 分頁內容（卡片裡，不再包一層卡片，用分隔線分開）

struct DetailTabContent: View {
    let tab: DetailTab
    let detail: CardDetail?
    let card: Card

    private static let examplesCollocationLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pattern = detail?.pattern {
                patternContent(pattern)
            } else if let word = detail?.word {
                wordContent(word)
            } else if let phrase = detail?.phrase {
                phraseContent(phrase)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func wordContent(_ word: WordDetail) -> some View {
        switch tab {
        case .examples:
            let meanings = word.meanings.filter { $0.zh != nil && !$0.examples.isEmpty }
            ForEach(Array(meanings.enumerated()), id: \.offset) { index, meaning in
                if index > 0 { divider }
                MeaningLabel(meaning: meaning)
                ForEach(Array(meaning.examples.enumerated()), id: \.offset) { _, example in
                    ExampleLines(en: example.en, zh: example.zh)
                }
            }
            // 例句下面順便放幾個主要搭配（常用的排前面），完整的在「搭配」分頁
            let collocations = word.allCollocations.prefix(Self.examplesCollocationLimit)
            if !collocations.isEmpty {
                divider
                DetailLabel("搭配")
                ForEach(Array(collocations.enumerated()), id: \.offset) { _, item in
                    CollocationLine(item: item)
                }
            }
        case .collocations:
            ForEach(Array(word.allCollocations.enumerated()), id: \.offset) { _, item in
                CollocationLine(item: item)
            }
        case .patterns:
            let meanings = word.meanings.filter { !$0.patterns.isEmpty }
            ForEach(Array(meanings.enumerated()), id: \.offset) { _, meaning in
                MeaningLabel(meaning: meaning)
                ForEach(Array(meaning.patterns.enumerated()), id: \.offset) { _, pattern in
                    PatternLine(pattern: pattern)
                }
            }
        case .phrases:
            separated(word.phrases) { PhraseLine(phrase: $0) }
        case .synonyms:
            separated(word.otherSynonyms) { SynonymLine(synonym: $0) }
        case .antonyms:
            FlowLayout(spacing: 8) {
                ForEach(Array(word.antonyms.enumerated()), id: \.offset) { _, item in
                    WordChip(word: item.word, zh: item.zh)
                }
            }
        case .confusables:
            separated(word.confusables) { ConfusableBlock(item: $0) }
        case .similar:
            separated(detail?.similar ?? []) { SimilarPairBlock(pair: $0) }
        case .errors:
            separated(word.commonErrors) { CommonErrorBlock(item: $0) }
        case .origin:
            OriginBlock(breakdown: word.breakdown, origin: word.origin)
        case .related:
            FlowLayout(spacing: 8) {
                ForEach(Array(word.related.enumerated()), id: \.offset) { _, item in
                    WordChip(word: item.word, zh: item.note)
                }
            }
        case .usage, .mix, .years, .structure, .variations:
            EmptyView()
        }
    }

    @ViewBuilder
    private func patternContent(_ pattern: PatternDetail) -> some View {
        switch tab {
        case .structure:
            PatternFormula(text: pattern.pattern, size: 17)
            divider
            separated(pattern.slots) { PatternSlotLine(slot: $0) }
        case .examples:
            separated(pattern.examples) { PatternExampleBlock(example: $0) }
        case .usage:
            PatternUsageBlock(pattern: pattern)
        case .variations:
            separated(pattern.variations) { PatternVariationBlock(variation: $0) }
        case .collocations:
            separated(pattern.collocations) { PatternCollocationLine(item: $0) }
        case .similar:
            separated(pattern.similar) { PatternSimilarBlock(item: $0) }
        case .errors:
            separated(pattern.errors) { PatternErrorBlock(item: $0) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func phraseContent(_ phrase: PhraseDetail) -> some View {
        switch tab {
        case .usage:
            bodyText(phrase.use)
        case .mix:
            bodyText(phrase.mix)
        case .years:
            Text("學測考過 \(phrase.yearList.count.formatted()) 次")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.er.text)
            Text(phrase.yearList.joined(separator: "、"))
                .font(.erMono)
                .foregroundStyle(Color.er.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            if let ex = phrase.ex {
                ExampleLines(en: ex, zh: phrase.exZh)
            }
        }
    }

    private var divider: some View {
        Divider().overlay(Color.er.outline)
    }

    private func bodyText(_ text: String?) -> some View {
        Text(text ?? "")
            .font(.body)
            .foregroundStyle(Color.er.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func separated<Item, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            if index > 0 { divider }
            row(item)
        }
    }
}

/// 「adj. 抽象的；理論的」小標
private struct MeaningLabel: View {
    let meaning: WordDetail.Meaning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let pos = meaning.pos {
                Text(pos)
                    .font(.erMono.weight(.semibold))
                    .foregroundStyle(Color.er.info)
            }
            Text(meaning.zh ?? "")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.er.textSecondary)
        }
    }
}

#Preview("淺色") {
    @Previewable @State var tab = DetailTab.examples
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.word == "abstract" }
    if let card {
        let detail = CardDetail.load(for: card.id, in: container.mainContext)
        VStack(alignment: .leading, spacing: 12) {
            DetailTabBar(tabs: DetailTab.available(for: detail), selection: $tab)
            ScrollView {
                DetailTabContent(tab: tab, detail: detail, card: card)
            }
        }
        .padding(Theme.Spacing.page)
        .erPageBackground()
        .modelContainer(container)
    }
}

#Preview("深色") {
    @Previewable @State var tab = DetailTab.similar
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.word == "abstract" }
    if let card {
        let detail = CardDetail.load(for: card.id, in: container.mainContext)
        VStack(alignment: .leading, spacing: 12) {
            DetailTabBar(tabs: DetailTab.available(for: detail), selection: $tab)
            ScrollView {
                DetailTabContent(tab: tab, detail: detail, card: card)
            }
        }
        .padding(Theme.Spacing.page)
        .erPageBackground()
        .modelContainer(container)
        .preferredColorScheme(.dark)
    }
}
