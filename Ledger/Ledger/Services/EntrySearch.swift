import Foundation
import FoundationModels

@Generable(description: "把一句搜尋記帳的話整理成篩選條件")
struct AISearchQuery {
    @Guide(description: "要找的商家、品項或備註關鍵字，最多 5 個；說的是一類東西時，列出常見的具體名稱，例如「飲料」→ 飲料、奶茶、咖啡、茶、可樂。沒有就留空")
    var keywords: [String]
    @Guide(description: "從分類清單選出相關的分類，必須照抄清單中的名稱；沒有就留空")
    var categories: [String]
    @Guide(description: "支出填 expense，收入填 income，沒說填 any")
    var kind: String
    @Guide(description: "金額下限，例如「超過 500」填 500；沒說填 0")
    var minAmount: Double
    @Guide(description: "金額上限，例如「100 以下」填 100；沒說填 0")
    var maxAmount: Double
    @Guide(description: "開始日期 yyyy-MM-dd，依參考日期換算；沒說時間填空字串")
    var startDate: String
    @Guide(description: "結束日期 yyyy-MM-dd（包含這天）；沒說時間填空字串")
    var endDate: String
}

/// 用一句話搜尋記帳：「上個月在全家買的飲料」「超過 500 的餐廳」
@MainActor
enum EntrySearch {
    struct Filter: Equatable {
        var keywords: [String] = []
        var categories: [String] = []
        var kind: EntryKind?
        var minAmount: Double?
        var maxAmount: Double?
        var start: Date?
        var end: Date?

        /// 給使用者看的條件摘要
        var summary: String {
            var parts: [String] = []
            if let s = start, let e = end {
                parts.append(s.formatted(.dateTime.month().day()) + "–" + e.formatted(.dateTime.month().day()))
            } else if let s = start {
                parts.append(s.formatted(.dateTime.month().day()) + " 之後")
            } else if let e = end {
                parts.append(e.formatted(.dateTime.month().day()) + " 之前")
            }
            if kind == .expense { parts.append("支出") }
            if kind == .income { parts.append("收入") }
            let words = categories + keywords.filter { k in !categories.contains(k) }
            if !words.isEmpty { parts.append(words.prefix(4).joined(separator: "、")) }
            if let lo = minAmount { parts.append("≥ \(Int(lo))") }
            if let hi = maxAmount { parts.append("≤ \(Int(hi))") }
            return parts.joined(separator: "・")
        }

        func matches(_ e: Entry) -> Bool {
            if let kind, e.kind != kind { return false }
            if let minAmount, e.amount < minAmount { return false }
            if let maxAmount, e.amount > maxAmount { return false }
            if let start, e.date < start { return false }
            if let end, e.date >= end { return false }
            if keywords.isEmpty && categories.isEmpty { return true }
            if let c = e.category, categories.contains(where: { $0 == c.name || $0 == c.main.name }) { return true }
            return keywords.contains { EntrySearch.text(e, contains: $0) }
        }
    }

    /// 一般文字搜尋：商家、備註、分類、分店、發票品項；連鎖店不同寫法算同一家
    nonisolated static func text(_ e: Entry, contains q: String) -> Bool {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if e.title.localizedCaseInsensitiveContains(q) || e.note.localizedCaseInsensitiveContains(q) { return true }
        if let c = e.category, c.name.contains(q) || c.main.name.contains(q) { return true }
        if let b = e.branch, b.localizedCaseInsensitiveContains(q) { return true }
        if let r = e.receiptJSON, r.localizedCaseInsensitiveContains(q) { return true }
        if let b = BrandLogo.brand(for: q), BrandLogo.brand(for: e.title)?.id == b.id { return true }
        return false
    }

    /// 短的關鍵字直接比對就好；像一句話的才交給模型
    nonisolated static func looksLikeSentence(_ q: String) -> Bool {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard t.count >= 4 else { return false }
        let hints = ["上個", "這個", "本月", "上月", "今天", "昨天", "前天", "週", "星期", "禮拜", "月", "年",
                     "超過", "以上", "以下", "低於", "多於", "買", "花", "的", "收入", "支出", "在"]
        return t.contains(" ") || t.rangeOfCharacter(from: .decimalDigits) != nil || hints.contains { t.contains($0) }
    }

    private static var session: LanguageModelSession?

    /// 先把模型載進來，按下搜尋時比較快
    static func prewarm() {
        guard NoticeParser.aiAvailable, session == nil else { return }
        let s = makeSession()
        s.prewarm()
        session = s
    }

    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
        你把使用者搜尋記帳的一句話整理成篩選條件。
        只填句子裡有提到的條件，沒提到的留空、填 0 或 any。
        日期一律依照提供的參考日期換算，不要自己猜今天幾號。
        商家名稱照使用者說的寫進 keywords，例如「全家」「麥當勞」。
        """)
    }

    static func parse(_ query: String) async throws -> Filter {
        guard NoticeParser.aiAvailable else { throw ReceiptService.ReceiptError.aiUnavailable(NoticeParser.aiStatusText) }
        // 每次搜尋用新的對話，避免上一次的內容影響這次
        let s = session ?? makeSession()
        session = nil
        defer { prewarm() }

        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func d(_ x: Date?) -> String { x.map { f.string(from: $0) } ?? "" }
        let thisMonth = DateText.monthInterval(today)
        let lastMonth = DateText.monthInterval(cal.date(byAdding: .month, value: -1, to: today) ?? today)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start
        let lastWeekStart = weekStart.flatMap { cal.date(byAdding: .day, value: -7, to: $0) }
        let yearStart = cal.dateInterval(of: .year, for: today)?.start
        let dayBefore = { (x: Date) in cal.date(byAdding: .day, value: -1, to: x) ?? x }

        let cats = Store.categories(income: false).map(\.name) + Store.categories(income: true).map(\.name)
        let prompt = """
        參考日期：
        今天 \(d(today))（\(today.formatted(.dateTime.weekday(.wide))))
        昨天 \(d(dayBefore(today)))
        本週 \(d(weekStart)) 起
        上週 \(d(lastWeekStart)) 到 \(d(weekStart.map(dayBefore)))
        本月 \(d(thisMonth.start)) 到 \(d(dayBefore(thisMonth.end)))
        上個月 \(d(lastMonth.start)) 到 \(d(dayBefore(lastMonth.end)))
        今年 \(d(yearStart)) 起
        分類清單：\(cats.joined(separator: "、"))

        搜尋：\(query)
        """
        let r = try await s.respond(to: prompt, generating: AISearchQuery.self,
                                    options: GenerationOptions(sampling: .greedy)).content

        var filter = Filter()
        filter.keywords = r.keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(6).map { $0 }
        filter.categories = r.categories.filter { cats.contains($0) }
        filter.kind = r.kind == "expense" ? .expense : (r.kind == "income" ? .income : nil)
        filter.minAmount = r.minAmount > 0 ? r.minAmount : nil
        filter.maxAmount = r.maxAmount > 0 ? r.maxAmount : nil
        filter.start = f.date(from: r.startDate)
        filter.end = f.date(from: r.endDate).flatMap { cal.date(byAdding: .day, value: 1, to: $0) }
        if let s = filter.start, let e = filter.end, e <= s { filter.end = nil }
        // 模型什麼都沒抓到，就退回用整句話比對
        if filter == Filter() { filter.keywords = [query] }
        return filter
    }
}
