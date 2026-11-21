import Foundation

/// 把解析好的單集檔案分成「劇 → 季 → 集」。
public enum EpisodeGrouping {
    public struct Input: Sendable, Hashable {
        public var fileId: String
        public var parsed: ParsedMedia
        public init(fileId: String, parsed: ParsedMedia) {
            self.fileId = fileId
            self.parsed = parsed
        }
    }

    public struct EpisodeRef: Sendable, Hashable {
        public var fileId: String
        public var episode: Int
        public var episodeEnd: Int?
    }

    public struct Season: Sendable, Hashable {
        public var number: Int
        public var episodes: [EpisodeRef]
    }

    public struct Show: Sendable, Hashable {
        public var key: String
        public var title: String
        public var year: Int?
        public var seasons: [Season]

        public var episodeCount: Int { seasons.reduce(0) { $0 + $1.episodes.count } }
    }

    /// 比對用的鍵：小寫、只留字母與數字（"The.Bear" 和 "the bear" 是同一部）
    public static func key(for title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    public static func group(_ items: [Input]) -> [Show] {
        var byKey: [String: (title: String, year: Int?, items: [Input])] = [:]
        for item in items where item.parsed.kind == .episode {
            let k = key(for: item.parsed.title)
            guard !k.isEmpty else { continue }
            var entry = byKey[k] ?? (item.parsed.title, nil, [])
            entry.year = entry.year ?? item.parsed.year
            entry.items.append(item)
            byKey[k] = entry
        }
        return byKey.map { k, entry in
            var seasons: [Int: [EpisodeRef]] = [:]
            for item in entry.items {
                let s = item.parsed.season ?? 1
                seasons[s, default: []].append(
                    EpisodeRef(fileId: item.fileId, episode: item.parsed.episode ?? 0, episodeEnd: item.parsed.episodeEnd)
                )
            }
            let sorted = seasons.keys.sorted { a, b in
                // 特別篇（第 0 季）排最後
                if a == 0 { return false }
                if b == 0 { return true }
                return a < b
            }.map { n in
                Season(number: n, episodes: seasons[n]!.sorted { ($0.episode, $0.fileId) < ($1.episode, $1.fileId) })
            }
            return Show(key: k, title: entry.title, year: entry.year, seasons: sorted)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 同一季中，這一集的下一集（自動播下一集用）；季末接下一季第一集
    public static func next(after fileId: String, in show: Show) -> EpisodeRef? {
        let all = show.seasons.filter { $0.number != 0 }.flatMap(\.episodes)
        guard let i = all.firstIndex(where: { $0.fileId == fileId }), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}
