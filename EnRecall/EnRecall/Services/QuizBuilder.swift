import Foundation
import SwiftData

/// 測驗的種類
enum QuizKind: String, CaseIterable, Identifiable {
    /// 看中文句子（挖空）寫英文：quiz-levelN.json
    case zhToEn
    /// 英文句子挖空填字：quiz-levelN.json，沒有題目的字用例句挖
    case cloze
    /// 片語例句挖空
    case phrase
    /// 句型例句挖空（固定字）
    case pattern

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zhToEn: "中翻英"
        case .cloze: "英文填空"
        case .phrase: "片語填空"
        case .pattern: "句型填空"
        }
    }

    var subtitle: String {
        switch self {
        case .zhToEn: "看中文句子，寫出空格的英文字"
        case .cloze: "看英文句子，填進少掉的字"
        case .phrase: "片語例句挖空，寫出整個片語"
        case .pattern: "句型例句挖空，寫出固定的字"
        }
    }

    var category: DeckCategory {
        switch self {
        case .zhToEn, .cloze: .word
        case .phrase: .phrase
        case .pattern: .pattern
        }
    }
}

/// 出題範圍
enum QuizScope: String, CaseIterable, Identifiable {
    /// 背過的字，記得的機率低的優先
    case learned
    /// 牌組裡所有的字（含還沒背的）
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .learned: "背過的"
        case .all: "全部"
        }
    }
}

struct QuizQuestion: Identifiable, Equatable {
    let id = UUID()
    let cardID: String
    let word: String
    let zh: String
    /// 題目句子（空格是 ＿＿）
    let prompt: String
    /// 題目句子的翻譯（英文填空才有）
    let promptTranslation: String?
    /// 中文提示：字義和詞性
    let hint: String?
    /// 接受的答案（第一個是主要答案）
    let answers: [String]
    /// 對答案時看的完整英文句子
    let reference: String?
    /// 中翻英：單字變化形也算對（中文句子看不出時態）
    let allowsInflections: Bool

    var mainAnswer: String { answers.first ?? word }

    /// 「a _ _ _ _ _ _   u _」：首字母和字母數
    var letterHint: String {
        mainAnswer.split(separator: " ").map { part in
            guard let first = part.first else { return "" }
            return ([String(first)] + Array(repeating: "_", count: max(part.count - 1, 0))).joined(separator: " ")
        }
        .joined(separator: "   ")
    }
}

enum QuizBuilder {
    static let blank = "＿＿"

    // MARK: 出題

    /// 從牌組挑字出題。learned：記得的機率低的先出（從最弱的兩倍數量裡隨機挑）；all：隨機
    @MainActor
    static func questions(kind: QuizKind, scope: QuizScope, count: Int, context: ModelContext, now: Date = Date()) throws -> [QuizQuestion] {
        let category = kind.category
        let decks = try context.fetch(FetchDescriptor<Deck>()).filter { $0.category == category }
        var cards = decks.flatMap(\.activeCards)

        switch scope {
        case .learned:
            let scheduler = FSRSScheduler()
            let ranked = cards
                .filter { !$0.isNew }
                .map { card -> (Card, Double) in
                    let elapsed = card.lastReview.map { now.timeIntervalSince($0) / 86_400 } ?? 0
                    return (card, scheduler.retrievability(elapsedDays: max(elapsed, 0), stability: card.stability))
                }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
            cards = Array(ranked.prefix(max(count * 2, 20))).shuffled() + Array(ranked.dropFirst(max(count * 2, 20)))
        case .all:
            cards.shuffle()
        }

        var result: [QuizQuestion] = []
        // 每張卡都要解開完整內容，不要整副牌都試
        for card in cards.prefix(count * 8) {
            let detail = CardDetail.load(for: card.id, in: context)
            if let question = question(kind: kind, card: card, detail: detail) {
                result.append(question)
                if result.count == count { break }
            }
        }
        return result
    }

    static func question(kind: QuizKind, card: Card, detail: CardDetail?) -> QuizQuestion? {
        let hint = [card.zh, card.pos].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
        switch kind {
        case .zhToEn:
            guard let item = detail?.quiz?.first(where: { $0.contextZh != nil && !$0.accepted.isEmpty }),
                  let prompt = item.contextZh else { return nil }
            let itemHint = [item.chinese, item.pos].compactMap { $0 }.joined(separator: "  ")
            return QuizQuestion(
                cardID: card.id, word: card.word, zh: card.zh,
                prompt: prompt, promptTranslation: nil, hint: itemHint.isEmpty ? hint : itemHint,
                answers: unique([item.target] + item.accepted), reference: item.referenceEn, allowsInflections: true
            )

        case .cloze:
            if let item = detail?.quiz?.first(where: { $0.contextEn != nil && !$0.acceptedEn.isEmpty }),
               let prompt = item.contextEn, prompt.contains(blank) {
                return QuizQuestion(
                    cardID: card.id, word: card.word, zh: card.zh,
                    prompt: prompt, promptTranslation: item.contextEnZh, hint: hint,
                    answers: unique([item.target] + item.acceptedEn),
                    reference: prompt.replacingOccurrences(of: blank, with: item.target), allowsInflections: false
                )
            }
            // 沒有題目的字：用例句挖
            let fromDetail: [(String, String?)] = detail?.word?.meanings.flatMap(\.examples).map { ($0.en, $0.zh) } ?? []
            let examples = fromDetail + sentence(card.example, card.exampleZh)
            return blanked(examples: examples, highlighter: Highlighter(word: card.word, forms: detail?.word?.forms),
                           card: card, hint: hint)

        case .phrase:
            let examples = sentence(detail?.phrase?.ex ?? card.example, detail?.phrase?.exZh ?? card.exampleZh)
            return blanked(examples: examples, highlighter: Highlighter(word: card.word), card: card, hint: card.zh)

        case .pattern:
            let fromDetail: [(String, String?)] = detail?.pattern?.examples.map { ($0.en, $0.zh) } ?? []
            let examples = fromDetail + sentence(card.example, card.exampleZh)
            return blanked(examples: examples.shuffled(), highlighter: Highlighter.forCard(card, detail: detail),
                           card: card, hint: card.zh)
        }
    }

    /// 第一個挖得到的例句：比對到的字換成 ＿＿，答案是句子裡實際的寫法（gave up、took）
    private static func blanked(examples: [(String, String?)], highlighter: Highlighter, card: Card, hint: String) -> QuizQuestion? {
        guard let regex = highlighter.regex else { return nil }
        for (en, zh) in examples {
            let ns = en as NSString
            let matches = regex.matches(in: en, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var prompt = en
            for match in matches.reversed() {
                guard let range = Range(match.range, in: prompt) else { continue }
                prompt.replaceSubrange(range, with: blank)
            }
            let answer = matches.map { ns.substring(with: $0.range) }.joined(separator: " ")
            return QuizQuestion(
                cardID: card.id, word: card.word, zh: card.zh,
                prompt: prompt, promptTranslation: zh, hint: hint,
                answers: [answer], reference: en, allowsInflections: false
            )
        }
        return nil
    }

    private static func sentence(_ en: String?, _ zh: String?) -> [(String, String?)] {
        guard let en, !en.isEmpty else { return [] }
        return [(en, zh)]
    }

    private static func unique(_ answers: [String]) -> [String] {
        var seen: Set<String> = []
        return answers.filter { seen.insert(normalize($0)).inserted }
    }

    // MARK: 對答案

    static func isCorrect(_ input: String, for question: QuizQuestion) -> Bool {
        let typed = normalize(input.replacingOccurrences(of: "...", with: " ").replacingOccurrences(of: "…", with: " "))
        guard !typed.isEmpty else { return false }
        for answer in question.answers {
            let expected = normalize(answer)
            if typed == expected { return true }
            if question.allowsInflections, !expected.contains(" "), Highlighter.inflections(of: expected).contains(typed) {
                return true
            }
        }
        return false
    }

    /// 小寫、彎引號換直的、多個空白變一個、去掉頭尾的標點
    static func normalize(_ text: String) -> String {
        Normalizer.normalize(text)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
            .trimmingCharacters(in: .whitespaces)
    }
}
