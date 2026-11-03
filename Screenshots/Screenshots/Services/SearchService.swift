import CoreSpotlight
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 搜尋用的截圖快照（不可變、可跨執行緒）。
struct SearchDocument: Sendable, Equatable {
    var id: String
    var title: String
    var summary: String
    var ocrText: String
    var keywords: [String]
    var category: String?
    var createdAt: Date
}

struct SearchHit: Sendable, Equatable {
    var document: SearchDocument
    var score: Int
}

/// 關鍵字搜尋：對標題、摘要、OCR 全文、關鍵字比對，依相關度與時間排序。
enum SearchService {
    enum Mode: Sendable {
        /// 每個字詞都要命中（搜尋列）
        case all
        /// 任一字詞命中即可（問答工具）
        case any
    }

    /// 把查詢拆成字詞：依空白與標點分開、去重、轉小寫。
    static func terms(from query: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",，、。；;：:？?！!「」『』\"'()（）"))
        var seen = Set<String>()
        var result: [String] = []
        for part in query.components(separatedBy: separators) {
            let term = part.trimmingCharacters(in: .whitespaces).lowercased()
            guard !term.isEmpty, !seen.contains(term) else { continue }
            seen.insert(term)
            result.append(term)
        }
        return result
    }

    /// 單一文件的分數；`nil` 代表不符合。
    /// 權重：標題 8、關鍵字 6、分類 5、摘要 4、OCR 全文 2（再依出現次數加分，最多 +3）。
    static func score(_ doc: SearchDocument, terms: [String], mode: Mode = .all) -> Int? {
        guard !terms.isEmpty else { return nil }
        let title = doc.title.lowercased()
        let summary = doc.summary.lowercased()
        let ocr = doc.ocrText.lowercased()
        let keywords = doc.keywords.map { $0.lowercased() }
        let category = doc.category?.lowercased() ?? ""

        var total = 0
        var matchedTerms = 0
        for term in terms {
            var termScore = 0
            if title.contains(term) { termScore += 8 }
            if keywords.contains(where: { $0.contains(term) || term.contains($0) && !$0.isEmpty }) { termScore += 6 }
            if !category.isEmpty && category == term { termScore += 5 }
            if summary.contains(term) { termScore += 4 }
            let ocrCount = occurrences(of: term, in: ocr)
            if ocrCount > 0 { termScore += 2 + min(ocrCount - 1, 3) }
            if termScore > 0 { matchedTerms += 1 }
            total += termScore
        }
        switch mode {
        case .all where matchedTerms < terms.count: return nil
        case .any where matchedTerms == 0: return nil
        default: return total
        }
    }

    /// 排序：分數高的在前；同分時新的在前。
    static func rank(_ docs: [SearchDocument], query: String, mode: Mode = .all, limit: Int? = nil) -> [SearchHit] {
        let terms = terms(from: query)
        var hits = docs.compactMap { doc in
            score(doc, terms: terms, mode: mode).map { SearchHit(document: doc, score: $0) }
        }
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.document.createdAt > $1.document.createdAt
        }
        if let limit { return Array(hits.prefix(limit)) }
        return hits
    }

    static func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: [], range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    /// 取出命中字附近的一段文字（給搜尋結果顯示）。
    static func snippet(in text: String, terms: [String], radius: Int = 28) -> String? {
        for term in terms {
            guard let range = text.range(of: term, options: .caseInsensitive) else { continue }
            let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
            var result = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
            if start > text.startIndex { result = "…" + result }
            if end < text.endIndex { result += "…" }
            return result
        }
        return nil
    }

    /// 把命中字反白。
    static func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        for term in terms where !term.isEmpty {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let range = attributed[searchStart...].range(of: term, options: .caseInsensitive) {
                attributed[range].backgroundColor = Color.yellow.opacity(0.45)
                attributed[range].inlinePresentationIntent = .stronglyEmphasized
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}

/// Core Spotlight 索引：讓系統搜尋找得到截圖。
enum SpotlightIndexer {
    static let domain = "com.eason3436.screenshots.items"

    static func index(_ doc: SearchDocument, thumbnailData: Data?) async {
        let attributes = CSSearchableItemAttributeSet(contentType: .image)
        attributes.title = doc.title.isEmpty ? "截圖" : doc.title
        attributes.contentDescription = doc.summary
        attributes.keywords = doc.keywords + (doc.category.map { [$0] } ?? [])
        attributes.textContent = doc.ocrText
        attributes.contentCreationDate = doc.createdAt
        attributes.thumbnailData = thumbnailData
        let item = CSSearchableItem(uniqueIdentifier: doc.id, domainIdentifier: domain, attributeSet: attributes)
        do {
            try await CSSearchableIndex.default().indexSearchableItems([item])
        } catch {
            appLog.error("Spotlight 索引失敗：\(error.localizedDescription)")
        }
    }

    static func remove(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids)
        } catch {
            appLog.error("Spotlight 刪除失敗：\(error.localizedDescription)")
        }
    }

    static func removeAll() async {
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
        } catch {
            appLog.error("Spotlight 清除失敗：\(error.localizedDescription)")
        }
    }
}
