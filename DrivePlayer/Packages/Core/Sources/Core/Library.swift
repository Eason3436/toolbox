import Foundation

/// 單集標題：TMDB 沒有正式標題時會給「第 5 集」「Episode 5」，前面已經寫了集數就不要再寫一次
public enum EpisodeTitle {
    private static let patterns: [String] = [
        #"^第\s*[0-9０-９一二三四五六七八九十百千零〇两兩]+\s*[集話话回]$"#,
        #"^(episode|ep|e)\s*\.?\s*[0-9]+$"#,
        #"^[0-9]+$"#,
        #"^(エピソード|에피소드)\s*[0-9]+$"#,
        #"^[0-9]+\s*(話|화|회)$"#,
    ]

    /// 是不是只有集數、沒有內容的標題
    public static func isGeneric(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        return patterns.contains { t.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// 有意義的標題才回傳
    public static func meaningful(_ title: String?) -> String? {
        guard let title, !isGeneric(title) else { return nil }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 首頁的分類：類型、評分、年代、分級
public enum CategoryKind: String, CaseIterable, Sendable, Codable, Hashable {
    case genre, rating, decade, certification

    public var title: String {
        switch self {
        case .genre: "類型"
        case .rating: "評分"
        case .decade: "發行年代"
        case .certification: "分級"
        }
    }
}

public enum LibraryCategory {
    /// 7.8 →「7」（7 分台）；滿分 10 併進 9 分台
    public static func ratingBucket(_ rating: Double?) -> Int? {
        guard let rating, rating > 0 else { return nil }
        return min(9, Int(rating.rounded(.down)))
    }

    /// 2025 → 2020
    public static func decade(_ year: Int?) -> Int? {
        guard let year, year >= 1880 else { return nil }
        return year / 10 * 10
    }

    /// 一部片屬於哪些分類（類型可以有好幾個）
    public static func values(_ kind: CategoryKind, genres: [String], rating: Double?, year: Int?, certification: String?) -> [String] {
        switch kind {
        case .genre:
            var seen: Set<String> = []
            return genres.map { GenreNames.name($0) }.filter { seen.insert($0).inserted }
        case .rating:
            return ratingBucket(rating).map { [String($0)] } ?? []
        case .decade:
            return decade(year).map { [String($0)] } ?? []
        case .certification:
            guard let c = certification?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return [] }
            return [c]
        }
    }

    /// 顯示的名字：「8 分」「2020 年代」
    public static func name(_ kind: CategoryKind, _ value: String) -> String {
        switch kind {
        case .genre, .certification: value
        case .rating: "\(value) 分"
        case .decade: "\(value) 年代"
        }
    }

    /// 分類的順序：評分、年代由高到低；類型、分級照數量多到少
    public static func sorted(_ kind: CategoryKind, counts: [String: Int]) -> [String] {
        switch kind {
        case .rating, .decade:
            return counts.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
        case .genre, .certification:
            return counts.keys.sorted { a, b in
                let ca = counts[a] ?? 0, cb = counts[b] ?? 0
                if ca != cb { return ca > cb }
                return a < b
            }
        }
    }
}
