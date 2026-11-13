import Foundation
import FoundationModels

@Generable(description: "從一句口語描述整理出的一筆記帳")
struct AIQuickEntry {
    @Guide(description: "商家或項目名稱，例如「麥當勞」「捷運」「薪水」；沒提到就用買的東西，例如「午餐」")
    var merchant: String
    @Guide(description: "金額，只要數字")
    var amount: Double
    @Guide(description: "收入（薪水、零用錢、退款、別人還錢）為 true，花錢為 false")
    var isIncome: Bool
    @Guide(description: "從分類清單選一個最適合的，必須照抄清單中的名稱")
    var category: String
    @Guide(description: "距離今天幾天：今天 0、昨天 1、前天 2；說「上週五」之類就換算成天數")
    var daysAgo: Int
    @Guide(description: "有提到時間就填 24 小時制「HH:mm」，例如「中午」12:00、「晚上七點」19:00；沒提到填空字串")
    var time: String
    @Guide(description: "有提到付款帳戶或卡片就從帳戶清單照抄名稱，沒提到填空字串")
    var account: String
    @Guide(description: "其他值得記下的細節（例如「跟同學」「買了兩杯」），沒有就填空字串")
    var note: String
}

/// 一句話記帳：「昨天中午麥當勞 150 用台新」
@MainActor
enum QuickEntryParser {
    struct Result {
        var merchant: String
        var amount: Double
        var isIncome: Bool
        var category: Category?
        var date: Date
        var account: Account?
        var note: String
    }

    static func parse(_ sentence: String) async throws -> Result {
        guard NoticeParser.aiAvailable else { throw ReceiptService.ReceiptError.aiUnavailable(NoticeParser.aiStatusText) }
        let cats = Store.categories()
        let accounts = Store.accounts().filter { !$0.archived }
        let today = Date.now.formatted(.dateTime.year().month().day().weekday(.wide).hour().minute())
        let session = LanguageModelSession(instructions: """
        你是記帳 App 的助理。使用者會用一句口語描述一筆花費或收入，請整理成記帳資料。
        金額可能寫成「150」「150元」「一百五」「1.5k」，一律換成數字。
        沒說時間就當作現在；分類要依照買的東西判斷，例如奶茶是飲料、便當是午餐或晚餐。
        \(MealTime.hint)
        """)
        let prompt = """
        現在時間：\(today)
        分類清單：\(cats.map(\.name).joined(separator: "、"))
        帳戶清單：\(accounts.map(\.name).joined(separator: "、"))

        使用者說：\(sentence)
        """
        let r = try await session.respond(to: prompt, generating: AIQuickEntry.self).content

        let cal = Calendar.current
        var date = cal.date(byAdding: .day, value: -max(0, min(r.daysAgo, 365)), to: .now) ?? .now
        let hm = r.time.split(separator: ":").compactMap { Int($0) }
        if hm.count == 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]) {
            date = cal.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: date) ?? date
        }
        let pool = cats.filter { $0.isIncome == r.isIncome }
        let category = pool.first { $0.name == r.category }
            ?? pool.first { !r.category.isEmpty && ($0.name.contains(r.category) || r.category.contains($0.name)) }
        let account = accounts.first { $0.name == r.account }
            ?? accounts.first { !r.account.isEmpty && $0.name.localizedCaseInsensitiveContains(r.account) }
        return Result(merchant: r.merchant.trimmingCharacters(in: .whitespaces), amount: abs(r.amount),
                      isIncome: r.isIncome, category: category, date: date, account: account,
                      note: r.note.trimmingCharacters(in: .whitespaces))
    }
}

extension Receipt {
    /// 發票上的日期（例如 2026/11/3 11:04:00、2026-11-03 11:04、115/11/03）
    var parsedDate: Date? {
        let s = date.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy/M/d HH:mm:ss", "yyyy/M/d HH:mm", "yyyy-M-d HH:mm:ss", "yyyy-M-d HH:mm", "yyyy/M/d", "yyyy-M-d"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        // 民國年
        let parts = s.split(whereSeparator: { "/-. ".contains($0) }).compactMap { Int($0) }
        if parts.count >= 3, parts[0] < 200 {
            return Calendar.current.date(from: DateComponents(year: parts[0] + 1911, month: parts[1], day: parts[2],
                                                              hour: parts.count > 3 ? parts[3] : nil,
                                                              minute: parts.count > 4 ? parts[4] : nil))
        }
        return nil
    }
}
