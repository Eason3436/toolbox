import Testing
import Foundation
@testable import Recap

struct ScheduleTests {
    private func date(_ string: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: string)!
    }

    @Test func weekdayWindow() {
        let rule = ScheduleRule(weekdays: [4], startMinute: 9 * 60, endMinute: 18 * 60) // 週三
        // 2026-11-04 是星期三
        #expect(rule.windowEnd(containing: date("2026-11-04 10:00")) == date("2026-11-04 18:00"))
        #expect(rule.windowEnd(containing: date("2026-11-04 18:00")) == nil)
        #expect(rule.windowEnd(containing: date("2026-11-05 10:00")) == nil)
    }

    @Test func overnightWindow() {
        let rule = ScheduleRule(weekdays: [4], startMinute: 22 * 60, endMinute: 2 * 60)
        #expect(rule.windowEnd(containing: date("2026-11-04 23:00")) == date("2026-11-05 02:00"))
        #expect(rule.windowEnd(containing: date("2026-11-05 01:00")) == date("2026-11-05 02:00"))
        #expect(rule.windowEnd(containing: date("2026-11-05 03:00")) == nil)
    }
}

struct ChunkTests {
    @Test func chunksStayUnderBudget() {
        let text = (0..<400).map { "第\($0)句：今天開會討論了下週的產品發表時程與分工。" }.joined(separator: "\n")
        let chunks = Summarizer.chunk(text, budget: 500)
        #expect(chunks.count > 1)
        for chunk in chunks { #expect(Summarizer.estimateTokens(chunk) <= 560) }
        #expect(chunks.joined().count >= text.count - 400 * 2)
    }

    @Test func englishIsCheaper() {
        #expect(Summarizer.estimateTokens("hello world this is a lecture") < Summarizer.estimateTokens("你好世界這是一堂課你好世界"))
    }
}

struct AskTests {
    @Test func tokensMixChineseAndEnglish() {
        let t = AskService.tokens("報告的 deadline 是星期五")
        #expect(t.contains("deadline"))
        #expect(t.contains("報告"))
        #expect(t.contains("星期"))
    }

    @Test func rankPrefersMatchingPassage() {
        let now = Date()
        let a = Passage(time: now, label: "09:00", text: "我們討論午餐要吃什麼")
        let b = Passage(time: now.addingTimeInterval(60), label: "09:05", text: "報告的截止日期是下週五，記得交給主管")
        let ranked = AskService.rank([a, b], question: "報告什麼時候要交", keywords: ["報告", "截止日期"])
        #expect(ranked.first?.label == "09:05")
    }
}
