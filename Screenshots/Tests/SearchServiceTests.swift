import Foundation
import Testing
@testable import Screenshots

@Suite("SearchService")
struct SearchServiceTests {
    private func doc(_ id: String, title: String = "", summary: String = "", ocr: String = "",
                     keywords: [String] = [], category: String? = nil, daysAgo: Double = 0) -> SearchDocument {
        SearchDocument(id: id, title: title, summary: summary, ocrText: ocr, keywords: keywords,
                       category: category, createdAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400))
    }

    @Test func splitsTermsOnSpacesAndPunctuation() {
        #expect(SearchService.terms(from: "  拉麵 店名，Ramen  ") == ["拉麵", "店名", "ramen"])
        #expect(SearchService.terms(from: "a a A") == ["a"])
        #expect(SearchService.terms(from: "   ").isEmpty)
    }

    @Test func findsTextInsideOCR() {
        let docs = [doc("1", ocr: "一蘭拉麵 台北本店\n營業時間 24 小時"), doc("2", ocr: "Hello world")]
        let hits = SearchService.rank(docs, query: "台北本店")
        #expect(hits.map(\.document.id) == ["1"])
    }

    @Test func isCaseInsensitive() {
        let docs = [doc("1", ocr: "Apple Store Order #123")]
        #expect(SearchService.rank(docs, query: "apple store").count == 1)
    }

    @Test func titleOutranksOCR() {
        let docs = [doc("ocr", ocr: "拉麵"), doc("title", title: "拉麵店")]
        #expect(SearchService.rank(docs, query: "拉麵").first?.document.id == "title")
    }

    @Test func newerWinsOnTie() {
        let docs = [doc("old", ocr: "咖啡", daysAgo: 10), doc("new", ocr: "咖啡", daysAgo: 1)]
        #expect(SearchService.rank(docs, query: "咖啡").map(\.document.id) == ["new", "old"])
    }

    @Test func allModeRequiresEveryTerm() {
        let docs = [doc("both", ocr: "拉麵 台北"), doc("one", ocr: "拉麵 高雄")]
        #expect(SearchService.rank(docs, query: "拉麵 台北").map(\.document.id) == ["both"])
        #expect(Set(SearchService.rank(docs, query: "拉麵 台北", mode: .any).map(\.document.id)) == ["both", "one"])
    }

    @Test func noMatchReturnsEmpty() {
        #expect(SearchService.rank([doc("1", ocr: "abc")], query: "不存在的東西").isEmpty)
    }

    @Test func keywordAndCategoryMatch() {
        let docs = [doc("k", keywords: ["機票"]), doc("c", category: "旅遊")]
        #expect(SearchService.rank(docs, query: "機票").map(\.document.id) == ["k"])
        #expect(SearchService.rank(docs, query: "旅遊").map(\.document.id) == ["c"])
    }

    @Test func respectsLimit() {
        let docs = (0..<10).map { doc("\($0)", ocr: "test") }
        #expect(SearchService.rank(docs, query: "test", limit: 3).count == 3)
    }

    @Test func snippetAroundMatch() {
        let text = String(repeating: "前", count: 50) + "目標字" + String(repeating: "後", count: 50)
        let snippet = SearchService.snippet(in: text, terms: ["目標字"], radius: 5)
        #expect(snippet == "…前前前前前目標字後後後後後…")
        #expect(SearchService.snippet(in: "abc", terms: ["x"]) == nil)
    }

    @Test func countsOccurrences() {
        #expect(SearchService.occurrences(of: "ab", in: "ab ab abab") == 4)
        #expect(SearchService.occurrences(of: "", in: "abc") == 0)
    }
}

@Suite("EntityExtractor")
struct EntityExtractorTests {
    @Test func detectsLinksAndPhones() {
        let text = "官網 https://example.com/menu\n訂位電話 02-2345-6789"
        let result = EntityExtractor.detect(in: text)
        #expect(result.urls.contains("https://example.com/menu"))
        #expect(!result.phoneNumbers.isEmpty)
    }

    @Test func detectsDates() {
        let result = EntityExtractor.detect(in: "Meeting on 2026-12-25 at 3:00 PM")
        #expect(!result.dates.isEmpty)
        #expect(result.dates.first?.date != nil)
    }

    @Test func mergeRemovesDuplicates() {
        let ai = ScreenshotEntities(
            dates: [],
            places: ["一蘭拉麵 台北本店"],
            urls: ["example.com/menu"],
            phoneNumbers: ["+886 2 2345 6789"],
            prices: ["NT$290", "NT$ 290"]
        )
        let detected = ScreenshotEntities(
            dates: [],
            places: ["一蘭拉麵台北本店"],
            urls: ["https://www.example.com/menu/"],
            phoneNumbers: ["02-2345-6789"],
            prices: []
        )
        let merged = EntityExtractor.merge(ai: ai, detected: detected)
        #expect(merged.places.count == 1)
        #expect(merged.urls == ["https://example.com/menu"])
        #expect(merged.phoneNumbers.count == 1)
        #expect(merged.prices.count == 1)
    }

    @Test func normalizesURL() {
        #expect(EntityExtractor.normalizeURL("example.com") == "https://example.com")
        #expect(EntityExtractor.normalizeURL("http://a.b") == "http://a.b")
    }

    @Test func phoneKeyTreatsCountryCodeAsLocal() {
        #expect(EntityExtractor.phoneKey("+886 912-345-678") == EntityExtractor.phoneKey("0912 345 678"))
    }

    @Test func entitiesRoundTripJSON() throws {
        let value = ScreenshotEntities(dates: [DetectedDate(text: "12/25", date: Date(timeIntervalSince1970: 0), duration: nil)],
                                       places: ["台北"], urls: [], phoneNumbers: [], prices: ["$10"])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(ScreenshotEntities.self, from: data) == value)
    }
}

@Suite("問答來源標記")
struct CitationTests {
    @Test func extractsAndStripsCitations() {
        let (text, ids) = AskService.extractCitations(from: "那家店叫一蘭拉麵 [#2]，在台北[#1]。", candidates: ["a", "b"])
        #expect(text == "那家店叫一蘭拉麵 ，在台北。")
        #expect(ids == ["b", "a"])
    }

    @Test func ignoresOutOfRange() {
        let (_, ids) = AskService.extractCitations(from: "答案 [#9]", candidates: ["a"])
        #expect(ids.isEmpty)
    }

    @Test func keepsOrdinaryBrackets() {
        let (text, _) = AskService.extractCitations(from: "價格 [含稅]", candidates: ["a"])
        #expect(text == "價格 [含稅]")
    }
}

@Suite("日期分段")
struct DayGroupingTests {
    struct Item: Identifiable { let id: Int; let date: Date }

    @Test func groupsByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let items = [
            Item(id: 1, date: base),
            Item(id: 2, date: base.addingTimeInterval(-3600)),
            Item(id: 3, date: base.addingTimeInterval(-86_400)),
        ]
        let sections = DayGrouping.sections(from: items, date: \.date, calendar: calendar)
        #expect(sections.count == 2)
        #expect(sections[0].items.map(\.id) == [1, 2])
        #expect(DayGrouping.title(for: base, now: base, calendar: calendar) == "今天")
        #expect(DayGrouping.title(for: base.addingTimeInterval(-86_400), now: base, calendar: calendar) == "昨天")
    }

    @Test func dateFilter() {
        let now = Date.now
        #expect(DateFilter.week.contains(now.addingTimeInterval(-86_400 * 3), now: now))
        #expect(!DateFilter.week.contains(now.addingTimeInterval(-86_400 * 10), now: now))
        #expect(DateFilter.any.contains(.distantPast, now: now))
    }
}
