import SwiftUI

/// 例句裡用螢光筆標出這張卡的字：單字含常見變化（dips、dipped、dipping、studies…）和單字庫的變化形；
/// 片語去掉 sb／sth 這類代稱，各段分開比對
struct Highlighter {
    let regex: NSRegularExpression?

    init(word: String, forms: String? = nil) {
        let pattern = Self.pattern(word: word, forms: forms)
        regex = pattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    /// 句型：標出固定不變的字（anchors），例如 "it is not until"、"that"
    init(anchors: [String]) {
        let pattern = Self.pattern(anchors: anchors)
        regex = pattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    /// 卡片用哪一種：句型卡標固定字，其他標單字（含變化形）
    static func forCard(_ card: Card, detail: CardDetail?) -> Highlighter {
        if let pattern = detail?.pattern {
            return Highlighter(anchors: pattern.anchors.isEmpty ? anchors(fromPattern: pattern.pattern) : pattern.anchors)
        }
        if card.deck?.category == .pattern {
            return Highlighter(anchors: anchors(fromPattern: card.word))
        }
        return Highlighter(word: card.word, forms: detail?.word?.forms)
    }

    func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let regex else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].backgroundColor = Color.er.highlight
        }
        return result
    }

    // MARK: 比對規則

    private static let placeholders: Set<String> = [
        "sb", "sth", "sb's", "sth's", "one", "one's", "oneself", "somebody", "something", "someone",
        "do", "doing", "to-v", "v-ing", "v", "n", "adj", "adv",
    ]

    static func pattern(word: String, forms: String?) -> String? {
        // 「not only … but also」：… 是空格，前後分成兩段
        let tokens = word.lowercased()
            .replacingOccurrences(of: #"\(.*?\)|\[.*?\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "...", with: " … ")
            .replacingOccurrences(of: "…", with: " … ")
            .split(whereSeparator: { $0 == " " || $0 == "/" })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        if tokens.count == 1, tokens[0] != "…" {
            var variants = inflections(of: tokens[0])
            for form in (forms ?? "").lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }) {
                variants.insert(String(form))
            }
            return alternation(variants)
        }

        // 片語：代稱切開成幾段，每段第一個字允許變化
        var chunks: [[String]] = [[]]
        for token in tokens {
            if placeholders.contains(token) || token == "…" {
                if !(chunks.last ?? []).isEmpty { chunks.append([]) }
            } else {
                chunks[chunks.count - 1].append(token)
            }
        }
        let parts = chunks.filter { !$0.isEmpty }.compactMap { chunk -> String? in
            guard let first = chunk.first else { return nil }
            let rest = chunk.dropFirst().map(NSRegularExpression.escapedPattern(for:))
            let head = "(?:" + inflections(of: first).map(NSRegularExpression.escapedPattern(for:)).sorted { $0.count > $1.count }.joined(separator: "|") + ")"
            return ([head] + rest).joined(separator: #"\s+"#)
        }
        guard !parts.isEmpty else { return nil }
        return #"\b(?:"# + parts.joined(separator: "|") + #")\b"#
    }

    static func pattern(anchors: [String]) -> String? {
        let parts = anchors.compactMap { anchor -> String? in
            let words = anchor.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return nil }
            // 句型裡每個字都可能變化：it is → it was、make it → made it 只認得 be／have／do 和規則變化
            return words.map { word in
                let forms = irregularGroups.first { $0.contains(word) } ?? inflections(of: word)
                return "(?:" + forms.map(NSRegularExpression.escapedPattern(for:)).sorted { $0.count > $1.count }.joined(separator: "|") + ")"
            }
            .joined(separator: #"\s+"#)
        }
        guard !parts.isEmpty else { return nil }
        return #"\b(?:"# + parts.sorted { $0.count > $1.count }.joined(separator: "|") + #")\b"#
    }

    private static let irregularGroups: [Set<String>] = [
        ["be", "is", "are", "was", "were", "been", "am", "being"],
        ["have", "has", "had", "having"],
        ["do", "does", "did", "done", "doing"],
    ]

    /// 句型公式裡的代號（S、V、N 這種全大寫的另外判斷）
    private static let slotTokens: Set<String> = ["Ving", "Ved", "Ven", "Vpp", "V-ing", "V-ed", "to-V", "Adj", "Adv"]

    /// 沒給 anchors 時從句型公式猜：「It is not until + 時間 + that + S + V」→ ["it is not until", "that"]。
    /// 去掉 + … ／ 括號、中文、S／V／N 這類代號和 sb／sth
    static func anchors(fromPattern text: String) -> [String] {
        let separated = text
            .replacingOccurrences(of: "...", with: "|")
            .replacingOccurrences(of: #"[+…/／()（）\[\]［］〔〕~～,，;；:：=]"#, with: "|", options: .regularExpression)
        var result: [String] = []
        for chunk in separated.split(separator: "|") {
            var run: [String] = []
            func flush() {
                if !run.isEmpty {
                    let anchor = run.joined(separator: " ")
                    if anchor.count > 1 { result.append(anchor) }
                    run = []
                }
            }
            for token in chunk.split(whereSeparator: \.isWhitespace).map(String.init) {
                let isEnglish = token.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'" || $0 == "-") }
                let isSlot = slotTokens.contains(token) || (token.count <= 4 && token == token.uppercased() && token != "I")
                if isEnglish, !isSlot, !placeholders.contains(token.lowercased()) {
                    run.append(token.lowercased())
                } else {
                    flush()
                }
            }
            flush()
        }
        return result
    }

    private static func alternation(_ variants: Set<String>) -> String? {
        let escaped = variants.filter { $0.count > 1 }.map(NSRegularExpression.escapedPattern(for:)).sorted { $0.count > $1.count }
        guard !escaped.isEmpty else { return nil }
        return #"\b(?:"# + escaped.joined(separator: "|") + #")\b"#
    }

    /// 規則變化（不處理 go→went 這種不規則）
    static func inflections(of word: String) -> Set<String> {
        let w = word.lowercased()
        var set: Set<String> = [w, w + "s", w + "es", w + "ed", w + "d", w + "ing", w + "er", w + "est", w + "ly"]
        let chars = Array(w)
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        if w.hasSuffix("e") {
            let stem = String(w.dropLast())
            set.formUnion([stem + "ing", stem + "ed", stem + "er", stem + "est"])
        }
        if w.hasSuffix("y"), chars.count > 1, !vowels.contains(chars[chars.count - 2]) {
            let stem = String(w.dropLast())
            set.formUnion([stem + "ies", stem + "ied", stem + "ier", stem + "iest", stem + "ily"])
        }
        if w.hasSuffix("ie") {
            set.insert(String(w.dropLast(2)) + "ying")
        }
        // 短字的子音－母音－子音結尾：dip → dipped、dipping
        if chars.count >= 3, let last = chars.last, !vowels.contains(last), !"wxy".contains(last),
           vowels.contains(chars[chars.count - 2]), !vowels.contains(chars[chars.count - 3]) {
            let doubled = w + String(last)
            set.formUnion([doubled + "ed", doubled + "ing", doubled + "er", doubled + "est"])
        }
        return set
    }
}

extension EnvironmentValues {
    /// 例句要標出的字（卡片背面、單字頁設定）
    @Entry var highlighter: Highlighter? = nil
}
