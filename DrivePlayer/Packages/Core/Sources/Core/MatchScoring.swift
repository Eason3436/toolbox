import Foundation

/// TMDB 搜尋結果裡挑最像的一個。片名 + 年份最優先。
public enum MatchScoring {
    public struct Candidate: Sendable, Hashable {
        public var id: Int
        public var title: String
        public var originalTitle: String?
        public var year: Int?
        public var popularity: Double

        public init(id: Int, title: String, originalTitle: String? = nil, year: Int? = nil, popularity: Double = 0) {
            self.id = id
            self.title = title
            self.originalTitle = originalTitle
            self.year = year
            self.popularity = popularity
        }
    }

    /// 0...1 的片名相似度（正規化後比較）
    public static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let ka = EpisodeGrouping.key(for: a)
        let kb = EpisodeGrouping.key(for: b)
        guard !ka.isEmpty, !kb.isEmpty else { return 0 }
        if ka == kb { return 1 }
        if ka.contains(kb) || kb.contains(ka) {
            let ratio = Double(min(ka.count, kb.count)) / Double(max(ka.count, kb.count))
            return 0.6 + 0.3 * ratio
        }
        let distance = levenshtein(Array(ka), Array(kb))
        return max(0, 1 - Double(distance) / Double(max(ka.count, kb.count)))
    }

    public static func score(query: String, year: Int?, candidate: Candidate) -> Double {
        var titleScore = titleSimilarity(query, candidate.title)
        if let o = candidate.originalTitle {
            titleScore = max(titleScore, titleSimilarity(query, o))
        }
        var s = titleScore * 100
        if let year, let cy = candidate.year {
            switch abs(year - cy) {
            case 0: s += 30
            case 1: s += 15
            default: s -= 25
            }
        }
        // 人氣只用來打破平手
        s += min(candidate.popularity, 100) / 100 * 5
        return s
    }

    /// 分數夠高才算比對成功，不然放進「未辨識」
    public static func best(query: String, year: Int?, candidates: [Candidate], threshold: Double = 70) -> Candidate? {
        let scored = candidates.map { ($0, score(query: query, year: year, candidate: $0)) }
        guard let top = scored.max(by: { $0.1 < $1.1 }), top.1 >= threshold else { return nil }
        return top.0
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] : min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
