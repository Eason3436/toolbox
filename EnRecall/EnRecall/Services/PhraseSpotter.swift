import Foundation
import SwiftData
import Vision
import NaturalLanguage
import UIKit

/// 拍照找片語、句型：Vision 在裝置上認出英文 → 跟本機的「學測片語總表」和句型卡比對。
/// 不用 AI：只會找到字典裡有的，但不會亂編，也不用網路。單字不找
enum PhraseSpotter {
    struct Match: Identifiable, Hashable, Sendable {
        let cardID: String
        let title: String
        let zh: String
        /// 片語總表裡標「句型」的，和句型卡
        let isPattern: Bool
        /// 照片裡出現的那一句
        let sentence: String
        /// 句子裡符合的位置（NSRange）
        let location: Int
        let length: Int

        var id: String { cardID }
    }

    struct Result: Sendable {
        let text: String
        let matches: [Match]
    }

    enum Failure: Error {
        case noText
    }

    static func scan(_ image: UIImage, container: ModelContainer) async throws -> Result {
        let text = try await recognizeText(in: image)
        guard !text.isEmpty else { throw Failure.noText }
        let matches = await Task.detached(priority: .userInitiated) {
            spot(in: text, candidates: loadCandidates(container: container))
        }.value
        return Result(text: text, matches: matches)
    }

    // MARK: 認字

    static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await Task.detached(priority: .userInitiated) { () throws -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return joinLines(lines)
        }.value
    }

    /// 行尾斷字（infor-\nmation）接回去，其他換行變空白
    static func joinLines(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
            .replacingOccurrences(of: #"-\n(?=[a-z])"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: 比對

    struct Candidate {
        let cardID: String
        let title: String
        let zh: String
        let isPattern: Bool
        let regex: NSRegularExpression
    }

    /// 片語總表、句型卡裡的每一張卡變成一個正規式
    static func loadCandidates(container: ModelContainer) -> [Candidate] {
        let context = ModelContext(container)
        let decks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        var seen = Set<String>()
        var result: [Candidate] = []
        for deck in decks where deck.category != .word {
            for card in deck.activeCards where seen.insert(card.id).inserted {
                let isPatternCard = deck.category == .pattern
                let pattern: String?
                if isPatternCard {
                    let anchors = CardDetail.load(for: card.id, in: context)?.pattern?.anchors ?? []
                    pattern = patternRegex(anchors: anchors.isEmpty ? Highlighter.anchors(fromPattern: card.word) : anchors)
                } else {
                    pattern = phraseRegex(card.word)
                }
                guard let pattern, let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                result.append(Candidate(
                    cardID: card.id,
                    title: card.word,
                    zh: card.zh.replacingOccurrences(of: "\n", with: "；"),
                    isPattern: isPatternCard || card.pos == "句型",
                    regex: regex
                ))
            }
        }
        return result
    }

    static func spot(in text: String, candidates: [Candidate]) -> [Match] {
        let sentences = splitSentences(text)
        var found: [(sentenceIndex: Int, match: Match)] = []
        for candidate in candidates {
            for (index, sentence) in sentences.enumerated() {
                let range = NSRange(location: 0, length: (sentence as NSString).length)
                guard let hit = candidate.regex.firstMatch(in: sentence, range: range) else { continue }
                found.append((index, Match(
                    cardID: candidate.cardID,
                    title: candidate.title,
                    zh: candidate.zh,
                    isPattern: candidate.isPattern,
                    sentence: sentence,
                    location: hit.range.location,
                    length: hit.range.length
                )))
                break
            }
        }
        // 「look forward to」找到了，就不要再列被它包住的「look forward」
        let kept = found.filter { item in
            !found.contains { other in
                other.sentenceIndex == item.sentenceIndex
                    && other.match.cardID != item.match.cardID
                    && other.match.length > item.match.length
                    && other.match.location <= item.match.location
                    && other.match.location + other.match.length >= item.match.location + item.match.length
            }
        }
        return kept
            .sorted { lhs, rhs in
                if lhs.sentenceIndex != rhs.sentenceIndex { return lhs.sentenceIndex < rhs.sentenceIndex }
                return lhs.match.location < rhs.match.location
            }
            .map(\.match)
    }

    static func splitSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result.isEmpty ? [text] : result
    }

    // MARK: 片語 → 正規式

    private static let placeholders: Set<String> = [
        "sb", "sth", "sb's", "sth's", "one's", "oneself", "somebody", "something", "someone",
        "somebody's", "someone's", "doing", "do", "v", "ving", "v-ing", "to-v", "n", "adj", "adv", "...", "…",
    ]

    /// 「be fond of sth」→ fond\s+of；「keep sb from doing」→ keep 的變化 + 中間 1–6 個字 + from。
    /// 括號裡是可省略的部分，不比對；至少要有兩個固定的字，不然太容易誤判
    static func phraseRegex(_ phrase: String) -> String? {
        let cleaned = phrase.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\(.*?\)|\[.*?\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "…", with: " … ")
            .replacingOccurrences(of: "...", with: " … ")
        var chunks: [[[String]]] = [[]]
        for raw in cleaned.split(whereSeparator: \.isWhitespace).map(String.init) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"“”"))
            guard !token.isEmpty else { continue }
            let options = token.split(separator: "/").map(String.init).filter { !placeholders.contains($0) }
            if options.isEmpty || placeholders.contains(token) {
                if !(chunks.last ?? []).isEmpty { chunks.append([]) }
            } else {
                chunks[chunks.count - 1].append(options)
            }
        }
        chunks = chunks.filter { !$0.isEmpty }
        // 開頭的 be 常常縮寫（I'm fond of），不比對
        if var first = chunks.first, first.first == ["be"] {
            first.removeFirst()
            if first.isEmpty { chunks.removeFirst() } else { chunks[0] = first }
        }
        let fixedWords = chunks.reduce(0) { $0 + $1.count }
        guard fixedWords >= 2 else { return nil }

        var parts: [String] = []
        for chunk in chunks {
            var words: [String] = []
            for (index, options) in chunk.enumerated() {
                var forms = Set<String>()
                for option in options {
                    // 每段第一個字常是動詞，允許變化；後面的介系詞照原樣
                    if index == 0 { forms.formUnion(wordForms(option)) } else { forms.insert(option) }
                }
                words.append(alternation(forms))
            }
            parts.append(words.joined(separator: #"\s+"#))
        }
        return #"\b"# + parts.joined(separator: #"(?:\s+[\w'’-]+){1,6}\s+"#) + #"\b"#
    }

    /// 句型：固定的字依序出現在同一句裡
    static func patternRegex(anchors: [String]) -> String? {
        let words = anchors.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
        let total = words.reduce(0) { $0 + $1.count }
        guard total >= 2 else { return nil }
        let parts: [String] = words.map { (anchor: [String]) -> String in
            anchor.map { alternation(wordForms($0)) }.joined(separator: #"\s+"#)
        }
        return #"\b"# + parts.joined(separator: #"\b.*?\b"#) + #"\b"#
    }

    private static func alternation(_ forms: Set<String>) -> String {
        let escaped: [String] = forms.map { NSRegularExpression.escapedPattern(for: $0) }.sorted { $0.count > $1.count }
        return "(?:" + escaped.joined(separator: "|") + ")"
    }

    /// 規則變化 + 常見的不規則動詞
    static func wordForms(_ word: String) -> Set<String> {
        let w = word.lowercased()
        var forms = Highlighter.inflections(of: w)
        for group in irregular where group.contains(w) {
            forms.formUnion(group)
        }
        return forms
    }

    private static let irregular: [Set<String>] = [
        ["be", "is", "are", "was", "were", "been", "am", "being"],
        ["have", "has", "had", "having"],
        ["do", "does", "did", "done", "doing"],
        ["go", "goes", "went", "gone", "going"],
        ["take", "takes", "took", "taken", "taking"],
        ["give", "gives", "gave", "given", "giving"],
        ["get", "gets", "got", "gotten", "getting"],
        ["make", "makes", "made", "making"],
        ["come", "comes", "came", "coming"],
        ["keep", "keeps", "kept", "keeping"],
        ["put", "puts", "putting"],
        ["run", "runs", "ran", "running"],
        ["set", "sets", "setting"],
        ["bring", "brings", "brought", "bringing"],
        ["break", "breaks", "broke", "broken", "breaking"],
        ["catch", "catches", "caught", "catching"],
        ["hold", "holds", "held", "holding"],
        ["let", "lets", "letting"],
        ["see", "sees", "saw", "seen", "seeing"],
        ["fall", "falls", "fell", "fallen", "falling"],
        ["find", "finds", "found", "finding"],
        ["stand", "stands", "stood", "standing"],
        ["think", "thinks", "thought", "thinking"],
        ["tell", "tells", "told", "telling"],
        ["leave", "leaves", "left", "leaving"],
        ["lose", "loses", "lost", "losing"],
        ["pay", "pays", "paid", "paying"],
        ["say", "says", "said", "saying"],
        ["show", "shows", "showed", "shown", "showing"],
        ["throw", "throws", "threw", "thrown", "throwing"],
        ["draw", "draws", "drew", "drawn", "drawing"],
        ["feel", "feels", "felt", "feeling"],
        ["grow", "grows", "grew", "grown", "growing"],
        ["hear", "hears", "heard", "hearing"],
        ["know", "knows", "knew", "known", "knowing"],
        ["lead", "leads", "led", "leading"],
        ["mean", "means", "meant", "meaning"],
        ["meet", "meets", "met", "meeting"],
        ["sell", "sells", "sold", "selling"],
        ["send", "sends", "sent", "sending"],
        ["speak", "speaks", "spoke", "spoken", "speaking"],
        ["spend", "spends", "spent", "spending"],
        ["stick", "sticks", "stuck", "sticking"],
        ["teach", "teaches", "taught", "teaching"],
        ["wear", "wears", "wore", "worn", "wearing"],
        ["win", "wins", "won", "winning"],
        ["write", "writes", "wrote", "written", "writing"],
        ["buy", "buys", "bought", "buying"],
        ["build", "builds", "built", "building"],
        ["cut", "cuts", "cutting"],
        ["deal", "deals", "dealt", "dealing"],
        ["forget", "forgets", "forgot", "forgotten", "forgetting"],
        ["hang", "hangs", "hung", "hanging"],
        ["lay", "lays", "laid", "laying"],
        ["lie", "lies", "lay", "lain", "lying"],
        ["rise", "rises", "rose", "risen", "rising"],
        ["shake", "shakes", "shook", "shaken", "shaking"],
        ["sit", "sits", "sat", "sitting"],
        ["strike", "strikes", "struck", "striking"],
        ["tear", "tears", "tore", "torn", "tearing"],
        ["turn", "turns", "turned", "turning"],
        ["drive", "drives", "drove", "driven", "driving"],
        ["eat", "eats", "ate", "eaten", "eating"],
        ["fight", "fights", "fought", "fighting"],
        ["hit", "hits", "hitting"],
        ["ride", "rides", "rode", "ridden", "riding"],
        ["seek", "seeks", "sought", "seeking"],
        ["shut", "shuts", "shutting"],
        ["wake", "wakes", "woke", "woken", "waking"],
        ["light", "lights", "lit", "lighted", "lighting"],
    ]
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
