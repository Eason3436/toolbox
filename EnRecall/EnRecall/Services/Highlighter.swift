import SwiftUI

/// 例句裡用螢光筆標出這張卡的字：單字含常見變化（dips、dipped、dipping、studies…）和單字庫的變化形；
/// 片語去掉 sb／sth 這類代稱，各段分開比對
struct Highlighter {
    let regex: NSRegularExpression?

    init(word: String, forms: String? = nil) {
        let pattern = Self.pattern(word: word, forms: forms)
        regex = pattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
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
        let tokens = word.lowercased()
            .replacingOccurrences(of: #"\(.*?\)|\[.*?\]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "…" })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        if tokens.count == 1 {
            var variants = inflections(of: tokens[0])
            for form in (forms ?? "").lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }) {
                variants.insert(String(form))
            }
            return alternation(variants)
        }

        // 片語：代稱切開成幾段，每段第一個字允許變化
        var chunks: [[String]] = [[]]
        for token in tokens {
            if placeholders.contains(token) {
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
