import Foundation

/// 單字正規化。規則必須跟 MCP 伺服器一致（EnRecall/supabase/DEPLOY.md 4.1）：
/// trim → 小寫 → 彎引號換成直引號 → 連續空白合併成一個
enum Normalizer {
    static func normalize(_ s: String) -> String {
        let lowered = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let quotes = lowered
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        return quotes
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 單字庫的單字 id
    static func wordID(_ word: String) -> String { "w:" + normalize(word) }

    /// 單字庫的片語 id
    static func phraseID(_ phrase: String) -> String { "p:" + normalize(phrase) }
}
