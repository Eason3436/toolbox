import SwiftUI
import SwiftData

/// 單字詳細（字典、牌組、複習卡共用）。單字庫的字顯示完整內容：
/// 字義與例句、句型、搭配、片語、近義／反義字、易混淆字、相似字對比、常見錯誤、字源。
/// 從 Claude 寫的字只有一個中文解釋和例句
struct WordDetailSheet: View {
    let card: Card
    /// 複習時打開：不顯示進度那一排
    var showsProgress = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var detail: CardDetail?
    @State private var isLoaded = false

    private var metaLine: String {
        [card.phonetic, card.pos].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                header
                if !isLoaded {
                    EmptyView()
                } else if let word = detail?.word {
                    WordDetailContent(word: word, similar: detail?.similar ?? [])
                } else if let phrase = detail?.phrase {
                    PhraseDetailContent(phrase: phrase)
                } else {
                    basicContent
                }
                if showsProgress {
                    progressGrid
                }
            }
            .padding(Theme.Spacing.page)
        }
        .erPageBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .onAppear {
            guard !isLoaded else { return }
            detail = CardDetail.load(for: card.id, in: context)
            isLoaded = true
        }
    }

    // MARK: 標題

    private var header: some View {
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
                if let forms = detail?.word?.forms {
                    Text(forms)
                        .font(.footnote)
                        .foregroundStyle(Color.er.textTertiary)
                        .accessibilityLabel("變化形 \(forms)")
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
    }

    // MARK: 沒有完整內容（從 Claude 寫的字）

    @ViewBuilder
    private var basicContent: some View {
        Text(card.zh)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.er.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)

        if let example = card.example, !example.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    DetailLabel("例句")
                    if card.source == .claude {
                        Chip(text: "AI 例句", style: .info)
                    }
                }
                ExampleLines(en: example, zh: card.exampleZh)
            }
            .erCard()
        }
    }

    // MARK: 進度

    private var progressGrid: some View {
        Grid(horizontalSpacing: Theme.Spacing.stack) {
            GridRow {
                infoCell(title: "下次複習", value: nextReviewText)
                infoCell(title: "已複習", value: "\(card.reps.formatted()) 次")
                infoCell(title: "牌組", value: card.deck?.name ?? "—")
            }
        }
        .padding(.top, Theme.Spacing.sectionTop)
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

// MARK: - 單字的完整內容

private struct WordDetailContent: View {
    let word: WordDetail
    let similar: [SimilarPair]

    @State private var showsAllCollocations = false

    private static let collocationLimit = 8

    private var meanings: [WordDetail.Meaning] { word.meanings.filter { $0.zh != nil } }

    private var collocations: [WordDetail.Collocation] {
        let all = word.allCollocations
        return showsAllCollocations ? all : Array(all.prefix(Self.collocationLimit))
    }

    private var synonyms: [WordDetail.Synonym] {
        word.synonyms.filter { $0.word.lowercased() != word.word.lowercased() }
    }

    var body: some View {
        ForEach(Array(meanings.enumerated()), id: \.offset) { _, meaning in
            MeaningBlock(meaning: meaning)
                .erCard()
        }

        if !word.allCollocations.isEmpty {
            SectionHeader(title: "搭配", trailing: word.allCollocations.count.formatted())
            collocationCard
        }

        if !word.phrases.isEmpty {
            SectionHeader(title: "片語")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(word.phrases.enumerated()), id: \.offset) { index, phrase in
                    if index > 0 { Divider().overlay(Color.er.outline) }
                    PhraseLine(phrase: phrase)
                }
            }
            .erCard()
        }

        if !synonyms.isEmpty {
            SectionHeader(title: "近義字")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(synonyms.enumerated()), id: \.offset) { index, synonym in
                    if index > 0 { Divider().overlay(Color.er.outline) }
                    SynonymLine(synonym: synonym)
                }
            }
            .erCard()
        }

        if !word.antonyms.isEmpty {
            SectionHeader(title: "反義字")
            FlowLayout(spacing: 8) {
                ForEach(Array(word.antonyms.enumerated()), id: \.offset) { _, antonym in
                    WordChip(word: antonym.word, zh: antonym.zh)
                }
            }
        }

        if !word.confusables.isEmpty {
            SectionHeader(title: "易混淆")
            ForEach(Array(word.confusables.enumerated()), id: \.offset) { _, item in
                ConfusableBlock(item: item)
                    .erCard()
            }
        }

        if !similar.isEmpty {
            SectionHeader(title: "相似字比較")
            ForEach(Array(similar.enumerated()), id: \.offset) { _, pair in
                SimilarPairBlock(pair: pair)
                    .erCard()
            }
        }

        if !word.commonErrors.isEmpty {
            SectionHeader(title: "常見錯誤")
            ForEach(Array(word.commonErrors.enumerated()), id: \.offset) { _, item in
                CommonErrorBlock(item: item)
                    .erCard()
            }
        }

        if !word.breakdown.isEmpty || word.origin != nil {
            SectionHeader(title: "字源")
            OriginBlock(breakdown: word.breakdown, origin: word.origin)
                .erCard()
        }

        if !word.related.isEmpty {
            SectionHeader(title: "同字根")
            FlowLayout(spacing: 8) {
                ForEach(Array(word.related.enumerated()), id: \.offset) { _, item in
                    WordChip(word: item.word, zh: item.note)
                }
            }
        }
    }

    private var collocationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(collocations.enumerated()), id: \.offset) { _, item in
                CollocationLine(item: item)
            }
            if word.allCollocations.count > Self.collocationLimit {
                Button {
                    withAnimation(.spring(duration: 0.3)) { showsAllCollocations.toggle() }
                } label: {
                    Text(showsAllCollocations ? "收起" : "顯示全部 \(word.allCollocations.count.formatted()) 個")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderless)
                .tint(Color.er.primary)
            }
        }
        .erCard()
    }
}

// MARK: - 片語總表的一條

private struct PhraseDetailContent: View {
    let phrase: PhraseDetail

    private var yearList: [String] {
        (phrase.years ?? "").split(separator: " ").map(String.init)
    }

    private var tierText: String? {
        switch phrase.tier {
        case 1: "高頻"
        case 2: "中頻"
        case 3: "低頻"
        default: nil
        }
    }

    var body: some View {
        if let zh = phrase.zh {
            Text(zh)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.er.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }

        FlowLayout(spacing: 6) {
            if let group = phrase.group { Chip(text: group) }
            if let tierText { Chip(text: tierText, style: .info) }
            if !yearList.isEmpty { Chip(text: "學測考過 \(yearList.count.formatted()) 次", systemImage: "calendar") }
        }

        if let use = phrase.use {
            SectionHeader(title: "用法")
            Text(use)
                .font(.body)
                .foregroundStyle(Color.er.text)
                .fixedSize(horizontal: false, vertical: true)
                .erCard()
        }

        if let ex = phrase.ex {
            SectionHeader(title: "例句")
            ExampleLines(en: ex, zh: phrase.exZh)
                .erCard()
        }

        if let mix = phrase.mix {
            SectionHeader(title: "易混淆")
            Text(mix)
                .font(.body)
                .foregroundStyle(Color.er.text)
                .fixedSize(horizontal: false, vertical: true)
                .erCard()
        }

        if !yearList.isEmpty {
            SectionHeader(title: "出現年度")
            Text(yearList.joined(separator: "、"))
                .font(.erMono)
                .foregroundStyle(Color.er.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }
}

// MARK: - 小元件

/// 區塊裡的小標（等寬、第三層文字色）
struct DetailLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.erLabel)
            .tracking(1.1)
            .foregroundStyle(Color.er.textTertiary)
    }
}

/// 英文例句 + 中文翻譯，旁邊有小喇叭
struct ExampleLines: View {
    let en: String
    let zh: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(en)
                    .font(.body)
                    .foregroundStyle(Color.er.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let zh, !zh.isEmpty {
                    Text(zh)
                        .font(.subheadline)
                        .foregroundStyle(Color.er.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            SpeakButton(text: en, size: 30)
        }
    }
}

/// 一個字義：詞性、中文、延伸說明、例句、句型
struct MeaningBlock: View {
    let meaning: WordDetail.Meaning

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let pos = meaning.pos {
                    Text(pos)
                        .font(.erMono.weight(.semibold))
                        .foregroundStyle(Color.er.info)
                }
                Text(meaning.zh ?? "")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.er.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let ext = meaning.ext {
                Text(ext)
                    .font(.footnote)
                    .foregroundStyle(Color.er.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(meaning.examples.enumerated()), id: \.offset) { _, example in
                ExampleLines(en: example.en, zh: example.zh)
            }
            if !meaning.patterns.isEmpty {
                DetailLabel("句型")
                    .padding(.top, 2)
                ForEach(Array(meaning.patterns.enumerated()), id: \.offset) { _, pattern in
                    PatternLine(pattern: pattern)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PatternLine: View {
    let pattern: WordDetail.Pattern

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pattern.pattern)
                .font(.erMono.weight(.semibold))
                .foregroundStyle(Color.er.text)
            if let en = pattern.en {
                Text(en)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let zh = pattern.zh {
                Text(zh)
                    .font(.footnote)
                    .foregroundStyle(Color.er.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.er.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

/// 搭配：常用的前面有星號
struct CollocationLine: View {
    let item: WordDetail.Collocation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.star == true ? "star.fill" : "circle.fill")
                .font(.system(size: item.star == true ? 11 : 5))
                .foregroundStyle(item.star == true ? Color.er.accent : Color.er.textTertiary)
                .frame(width: 14)
                .accessibilityLabel("常用")
                .accessibilityHidden(item.star != true)
            Text(item.en)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.er.text)
            if let zh = item.zh {
                Text(zh)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PhraseLine: View {
    let phrase: WordDetail.WordPhrase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(phrase.phrase)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                if let zh = phrase.zh {
                    Text(zh)
                        .font(.subheadline)
                        .foregroundStyle(Color.er.textSecondary)
                }
            }
            if let example = phrase.example {
                ExampleLines(en: example, zh: phrase.exampleZh)
            }
        }
    }
}

struct SynonymLine: View {
    let synonym: WordDetail.Synonym

    private var tags: [String] {
        (synonym.tag ?? []).compactMap { tag in
            switch tag {
            case "beyond": "延伸"
            case "formal": "正式"
            case "spoken": "口語"
            case "phrase": "片語"
            default: nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(synonym.word)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                if let zh = synonym.zh {
                    Text(zh)
                        .font(.subheadline)
                        .foregroundStyle(Color.er.textSecondary)
                }
                Spacer(minLength: 0)
                ForEach(tags, id: \.self) { tag in
                    Chip(text: tag)
                }
            }
            if let note = synonym.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let example = synonym.example {
                Text(example)
                    .font(.erMono)
                    .foregroundStyle(Color.er.text)
            }
        }
    }
}

/// 反義字、同字根：英文 + 中文的小膠囊
struct WordChip: View {
    let word: String
    let zh: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(word)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.er.text)
            if let zh {
                Text(zh)
                    .font(.footnote)
                    .foregroundStyle(Color.er.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.er.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.er.outline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// ✗ 錯的句子 ／ ✓ 對的句子
struct VerdictLine: View {
    let isCorrect: Bool
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isCorrect ? "checkmark" : "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(isCorrect ? Color.er.ratingGood : Color.er.danger)
                .frame(width: 14)
                .accessibilityLabel(isCorrect ? "正確" : "錯誤")
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.er.text)
                .strikethrough(!isCorrect, color: Color.er.danger.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ConfusableBlock: View {
    let item: WordDetail.Confusable

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let words = item.words {
                Text(words)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.er.text)
            }
            if let note = item.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let wrong = item.wrong { VerdictLine(isCorrect: false, text: wrong) }
            if let right = item.right { VerdictLine(isCorrect: true, text: right) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CommonErrorBlock: View {
    let item: WordDetail.CommonError

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let wrong = item.wrong {
                    Text(wrong)
                        .font(.body)
                        .strikethrough(color: Color.er.danger.opacity(0.6))
                        .foregroundStyle(Color.er.danger)
                }
                if item.wrong != nil && item.right != nil {
                    Image(systemName: "arrow.forward")
                        .font(.footnote)
                        .foregroundStyle(Color.er.textTertiary)
                        .accessibilityLabel("改成")
                }
                if let right = item.right {
                    Text(right)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.er.ratingGood)
                }
            }
            if let note = item.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let exWrong = item.exWrong { VerdictLine(isCorrect: false, text: exWrong) }
            if let exRight = item.exRight { VerdictLine(isCorrect: true, text: exRight) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SimilarPairBlock: View {
    let pair: SimilarPair

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                side(pair.a, zh: pair.aZh)
                side(pair.b, zh: pair.bZh)
            }
            if let diff = pair.diff {
                Text(diff)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !pair.points.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(pair.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                                .foregroundStyle(Color.er.textTertiary)
                            Text(point)
                                .foregroundStyle(Color.er.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.footnote)
                    }
                }
            }
            if let tip = pair.tip {
                Label {
                    Text(tip)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb")
                }
                .font(.subheadline)
                .foregroundStyle(Color.er.info)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.er.infoContainer, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
            if let exA = pair.exA { ExampleLines(en: exA.en, zh: exA.zh) }
            if let exB = pair.exB { ExampleLines(en: exB.en, zh: exB.zh) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func side(_ word: String, zh: String?) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(word)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.er.text)
            Text(zh ?? "")
                .font(.subheadline)
                .foregroundStyle(Color.er.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OriginBlock: View {
    let breakdown: [WordDetail.BreakdownPart]
    let origin: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !breakdown.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(Array(breakdown.enumerated()), id: \.offset) { _, part in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(part.part)
                                .font(.erMono.weight(.semibold))
                                .foregroundStyle(Color.er.text)
                            Text([part.type, part.gloss].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Color.er.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.er.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let origin {
                Text(origin)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 預覽

#Preview("單字 · 淺色") {
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.word == "abstract" }
    if let card {
        WordDetailSheet(card: card)
            .modelContainer(container)
    }
}

#Preview("單字 · 深色") {
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.word == "abstract" }
    if let card {
        WordDetailSheet(card: card)
            .modelContainer(container)
            .preferredColorScheme(.dark)
    }
}

#Preview("片語 · 淺色") {
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.word == "such as" }
    if let card {
        WordDetailSheet(card: card)
            .modelContainer(container)
    }
}

#Preview("片語 · 深色") {
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.word == "such as" }
    if let card {
        WordDetailSheet(card: card)
            .modelContainer(container)
            .preferredColorScheme(.dark)
    }
}

#Preview("Claude 的字 · 淺色") {
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.source == .claude }
    if let card {
        WordDetailSheet(card: card)
            .modelContainer(container)
    }
}

#Preview("Claude 的字 · 深色") {
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.source == .claude }
    if let card {
        WordDetailSheet(card: card)
            .modelContainer(container)
            .preferredColorScheme(.dark)
    }
}
