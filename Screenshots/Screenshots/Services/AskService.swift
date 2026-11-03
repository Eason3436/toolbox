import Foundation
import FoundationModels
import SwiftData
import Synchronization

/// 問答結果。
struct AskResult: Sendable {
    var answer: String
    var sourceIDs: [String]
    var notFound: Bool
}

/// 自然語言問答：模型呼叫本地搜尋工具取回候選截圖，再依內容作答。
enum AskService {
    static let notFoundAnswer = "找不到相關截圖。"

    static let instructions = """
    你是使用者的截圖助理，用台灣繁體中文回答。
    回答任何問題前，一定要先呼叫 searchScreenshots 工具搜尋使用者的截圖，可以換不同關鍵字多搜幾次。
    只能根據工具回傳的截圖內容作答，不可以編造或用常識補充。
    回答時在引用的內容後面標註來源編號，例如 [#1]。
    如果工具回傳的截圖都和問題無關，就只回答「找不到相關截圖。」
    回答要簡短，1～3 句。
    """

    static func ask(_ question: String, container: ModelContainer) async -> AskResult {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AskResult(answer: "請輸入問題。", sourceIDs: [], notFound: true) }

        let readiness = ModelReadiness.current
        guard readiness == .available else {
            return AskResult(answer: readiness.message, sourceIDs: [], notFound: true)
        }

        let recorder = SourceRecorder()
        let tool = ScreenshotSearchTool(container: container, recorder: recorder)
        let session = LanguageModelSession(tools: [tool], instructions: instructions)
        do {
            let response = try await session.respond(to: trimmed)
            let candidates = recorder.candidates
            // 工具沒找到任何截圖：一律回答找不到，避免模型編造
            guard !candidates.isEmpty else {
                return AskResult(answer: notFoundAnswer, sourceIDs: [], notFound: true)
            }
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("找不到相關截圖") {
                return AskResult(answer: notFoundAnswer, sourceIDs: [], notFound: true)
            }
            let (clean, cited) = extractCitations(from: text, candidates: candidates)
            let sources = cited.isEmpty ? Array(candidates.prefix(3)) : cited
            return AskResult(answer: clean, sourceIDs: sources, notFound: false)
        } catch {
            appLog.error("問答失敗：\(error.localizedDescription)")
            return AskResult(answer: "問答時發生錯誤：\(error.localizedDescription)", sourceIDs: [], notFound: true)
        }
    }

    /// 取出回答中的 [#n] 來源標記，並從文字中移除。
    static func extractCitations(from text: String, candidates: [String]) -> (String, [String]) {
        var cited: [String] = []
        var clean = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "[",
               let close = text[index...].firstIndex(of: "]"),
               text.distance(from: index, to: close) <= 12 {
                let inner = text[text.index(after: index)..<close]
                let numbers = inner.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if inner.contains("#"), !numbers.isEmpty {
                    for n in numbers where n >= 1 && n <= candidates.count {
                        let id = candidates[n - 1]
                        if !cited.contains(id) { cited.append(id) }
                    }
                    index = text.index(after: close)
                    continue
                }
            }
            clean.append(text[index])
            index = text.index(after: index)
        }
        let result = clean.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (result, cited)
    }
}

/// 記錄工具回傳過哪些截圖（編號 = 陣列位置 + 1）。
final class SourceRecorder: Sendable {
    private let storage = Mutex<[String]>([])

    var candidates: [String] { storage.withLock { $0 } }

    /// 加入並回傳每張的編號。
    func register(_ ids: [String]) -> [Int] {
        storage.withLock { (list: inout [String]) -> [Int] in
            ids.map { id -> Int in
                if let i = list.firstIndex(of: id) { return i + 1 }
                list.append(id)
                return list.count
            }
        }
    }
}

/// 給模型用的本地截圖搜尋工具。
struct ScreenshotSearchTool: Tool {
    let name = "searchScreenshots"
    let description = "搜尋使用者的截圖（標題、摘要、截圖中的文字、關鍵字），回傳最相關的幾張與其內容。"

    let container: ModelContainer
    let recorder: SourceRecorder

    @Generable
    struct Arguments {
        @Guide(description: "搜尋關鍵字，可用空白分隔多個詞，例如「拉麵 店名」")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let context = ModelContext(container)
        let items = (try? context.fetch(FetchDescriptor<ScreenshotItem>())) ?? []
        let hits = SearchService.rank(items.map(\.searchDocument), query: arguments.query, mode: .any, limit: 5)
        guard !hits.isEmpty else { return "沒有找到符合「\(arguments.query)」的截圖。" }

        let numbers = recorder.register(hits.map(\.document.id))
        let entitiesByID = Dictionary(items.map { ($0.assetID, $0.entities) }, uniquingKeysWith: { a, _ in a })
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: "zh_Hant_TW"))
        var lines = ["找到 \(hits.count) 張相關截圖："]
        for (hit, number) in zip(hits, numbers) {
            let doc = hit.document
            var parts = ["[#\(number)] \(doc.createdAt.formatted(dateStyle))"]
            if !doc.title.isEmpty { parts.append("標題：\(doc.title)") }
            if let category = doc.category { parts.append("分類：\(category)") }
            if !doc.summary.isEmpty { parts.append("摘要：\(doc.summary)") }
            if let entities = entitiesByID[doc.id] {
                if !entities.places.isEmpty { parts.append("地點：\(entities.places.prefix(3).joined(separator: "、"))") }
                if !entities.prices.isEmpty { parts.append("價格：\(entities.prices.prefix(3).joined(separator: "、"))") }
                if !entities.dates.isEmpty { parts.append("日期：\(entities.dates.prefix(3).map(\.text).joined(separator: "、"))") }
            }
            let excerpt = doc.ocrText.replacingOccurrences(of: "\n", with: " ").prefix(160)
            if !excerpt.isEmpty { parts.append("截圖文字：\(excerpt)") }
            lines.append(parts.joined(separator: "｜"))
        }
        return lines.joined(separator: "\n")
    }
}
