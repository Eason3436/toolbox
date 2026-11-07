import Foundation
import FoundationModels
import SwiftData

/// 從銀行通知拆出的交易
struct ParsedNotice: Sendable {
    var merchant: String
    var amount: Double
    var isIncome: Bool
    var currency: String
    var categoryName: String
    var cardLast4: String
    var usedAI: Bool
    /// Apple Intelligence 依商家與時間推測買了什麼（例如「早餐」「飲料」）
    var guess: String = ""
    /// 捷徑附上的位置（地址或地名）
    var place: String = ""
}

/// 用付款時間幫忙判斷買的是早餐、午餐、點心還是宵夜
enum MealTime {
    static func describe(_ date: Date) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date), m = cal.component(.minute, from: date)
        let wd = ["日", "一", "二", "三", "四", "五", "六"][cal.component(.weekday, from: date) - 1]
        let slot: String
        switch h {
        case 5..<10: slot = "早餐時段"
        case 10..<11: slot = "早午餐時段"
        case 11..<14: slot = "午餐時段"
        case 14..<17: slot = "下午茶／點心時段"
        case 17..<21: slot = "晚餐時段"
        case 21..<24, 0..<2: slot = "宵夜／零食時段"
        default: slot = "深夜"
        }
        return String(format: "星期%@ %02d:%02d（%@）", wd, h, m, slot)
    }

    static let hint = """
    同一家店在不同時間買的東西常常不同，請參考付款時間判斷買了什麼：
    便利商店、早餐店、咖啡店、超市、麵包店、手搖飲這類可能買吃喝的商家，
    早上 5–10 點多半是早餐，11–14 點是午餐，14–17 點是點心、下午茶或飲料，17–21 點是晚餐，21 點以後是宵夜或零食。
    分類清單裡有對應的分類（例如早餐、午餐、晚餐、點心、零食、飲料）就選它；沒有就選最接近的餐飲類。
    明顯不是吃喝的商家（加油站、交通、訂閱、百貨服飾）則照商家本身判斷，不要硬套時間。
    """
}

@Generable(description: "從銀行或信用卡通知中擷取出的一筆交易")
struct AINotice {
    @Guide(description: "商家或交易對象名稱，例如「全家便利商店」「Apple」「Uber Eats」。不要包含銀行名稱、卡別、卡號或「消費」「刷卡」等字。找不到就填「未知商家」。")
    var merchant: String

    @Guide(description: "交易金額，只要數字，不含幣別符號與千分位逗號。若有多個金額，選擇本次交易的金額，不是可用額度或餘額。")
    var amount: Double

    @Guide(description: "收入（入帳、轉入、退款、薪資）為 true；消費、扣款、轉出、繳費為 false")
    var isIncome: Bool

    @Guide(description: "交易幣別的 ISO 4217 代碼，例如 TWD、USD、JPY。沒寫幣別時台灣銀行通知視為 TWD。")
    var currency: String

    @Guide(description: "從提供的分類清單中選一個最適合這筆交易的分類名稱，必須完全照抄清單中的名稱")
    var category: String

    @Guide(description: "通知中出現的卡號或帳號末四碼，沒有就填空字串")
    var cardLast4: String

    @Guide(description: "依商家和付款時間推測買了什麼，2 到 6 個字，例如「早餐」「午餐便當」「飲料」「零食」「加油」，猜不出來就填空字串")
    var guess: String

    @Guide(description: "使用者另外附上的目前位置（地址、地名或經緯度），不是商家名稱；沒有就填空字串")
    var place: String
}

enum NoticeParser {
    static var aiAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var aiStatusText: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "可使用"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "這台裝置不支援 Apple Intelligence"
            case .appleIntelligenceNotEnabled: return "請到「設定」開啟 Apple Intelligence"
            case .modelNotReady: return "模型下載中，稍後再試"
            @unknown default: return "目前無法使用"
            }
        @unknown default: return "目前無法使用"
        }
    }

    static func parse(_ text: String, categories: [String], date: Date = .now) async -> ParsedNotice? {
        if aiAvailable, let ai = try? await parseWithAI(text, categories: categories, date: date), ai.amount > 0 {
            return ai
        }
        return parseWithRules(text, categories: categories)
    }

    static func parseWithAI(_ text: String, categories: [String], date: Date = .now) async throws -> ParsedNotice {
        let session = LanguageModelSession(instructions: """
        你是記帳助理。使用者會給你一則銀行、信用卡或電子支付的通知全文，請擷取出這筆交易的商家、金額、收支、幣別與卡號末四碼，並從分類清單中挑選最適合的分類。
        金額只取本次交易的金額，不要取可用餘額、額度或回饋點數。
        使用者可能在文字裡另外附上目前位置（地址、地名或經緯度），那是位置，不是商家名稱，請放在 place。
        \(MealTime.hint)
        """)
        let prompt = """
        分類清單：\(categories.joined(separator: "、"))
        付款時間：\(MealTime.describe(date))

        通知全文：
        \(text)
        """
        let response = try await session.respond(to: prompt, generating: AINotice.self)
        let r = response.content
        let ruleAmount = ruleAmount(in: text)
        return ParsedNotice(
            merchant: r.merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: abs(r.amount > 0 ? r.amount : (ruleAmount ?? 0)),
            isIncome: r.isIncome,
            currency: r.currency.count == 3 ? r.currency.uppercased() : "TWD",
            categoryName: r.category,
            cardLast4: String(r.cardLast4.filter(\.isNumber).suffix(4)),
            usedAI: true,
            guess: r.guess.trimmingCharacters(in: .whitespacesAndNewlines),
            place: r.place.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: 規則備援（沒有 Apple Intelligence 時）

    static func ruleAmount(in text: String) -> Double? {
        let t = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
        let patterns = [
            #"(?:NT\$|NTD|TWD|新台幣|新臺幣|台幣|臺幣|\$)\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#,
            #"(?:金額|消費|扣款|刷卡|入帳|轉入|轉出|支付|付款)[^0-9]{0,8}([0-9][0-9,]*(?:\.[0-9]+)?)"#,
            #"([0-9][0-9,]*(?:\.[0-9]+)?)\s*元"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let r = Range(m.range(at: 1), in: t),
               let v = Double(t[r].replacingOccurrences(of: ",", with: "")), v > 0 {
                return v
            }
        }
        return nil
    }

    static func parseWithRules(_ text: String, categories: [String]) -> ParsedNotice? {
        guard let amount = ruleAmount(in: text) else { return nil }
        let t = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let incomeWords = ["入帳", "轉入", "退款", "薪資", "存入", "收款"]
        let isIncome = incomeWords.contains { t.contains($0) }

        var merchant = "銀行通知"
        let merchantPatterns = [
            #"(?:於|在|商店|特店|商家)[:：]?\s*([^\s,，。;；0-9]{2,20})"#,
            #"([^\s,，。;；]{2,20})\s*(?:消費|刷卡|扣款)"#,
        ]
        for p in merchantPatterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let r = Range(m.range(at: 1), in: t) {
                merchant = String(t[r])
                break
            }
        }

        var last4 = ""
        if let re = try? NSRegularExpression(pattern: #"(?:末四碼|末4碼|尾號|卡號|\*{2,}|x{2,}|X{2,})[^0-9]{0,4}([0-9]{4})"#),
           let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r = Range(m.range(at: 1), in: t) {
            last4 = String(t[r])
        }

        var currency = "TWD"
        for c in ["USD", "JPY", "EUR", "CNY", "HKD", "KRW", "GBP"] where t.uppercased().contains(c) {
            currency = c
        }
        if t.contains("日圓") || t.contains("日幣") { currency = "JPY" }
        if t.contains("美元") || t.contains("美金") { currency = "USD" }

        return ParsedNotice(merchant: merchant, amount: amount, isIncome: isIncome, currency: currency,
                            categoryName: isIncome ? "其他收入" : "其他", cardLast4: last4, usedAI: false)
    }
}

/// 把辨識結果寫成一筆交易（捷徑與 App 內共用）
@MainActor
enum NoticeRecorder {
    struct Result {
        var entry: Entry
        var duplicate: Bool
        var summary: String
    }

    enum RecordError: LocalizedError {
        case cannotParse
        var errorDescription: String? { "看不出這則通知的金額，沒有記帳。" }
    }

    static func record(text: String, accountName: String? = nil, merchantOverride: String? = nil, amountOverride: Double? = nil, date: Date = .now) async throws -> Result {
        Store.seedIfNeeded()
        let ctx = Store.context
        let cats = Store.categories()

        var parsed: ParsedNotice
        if let amountOverride, amountOverride != 0 {
            parsed = ParsedNotice(merchant: merchantOverride ?? "", amount: abs(amountOverride), isIncome: false,
                                  currency: Prefs.mainCurrency, categoryName: "", cardLast4: "", usedAI: false)
            if parsed.merchant.isEmpty || parsed.categoryName.isEmpty, !text.isEmpty,
               let p = await NoticeParser.parse(text, categories: cats.map(\.name), date: date) {
                if parsed.merchant.isEmpty { parsed.merchant = p.merchant }
                parsed.categoryName = p.categoryName
                parsed.isIncome = p.isIncome
                parsed.cardLast4 = p.cardLast4
                parsed.usedAI = p.usedAI
                parsed.guess = p.guess
                parsed.place = p.place
            }
        } else {
            guard let p = await NoticeParser.parse(text, categories: cats.map(\.name), date: date) else { throw RecordError.cannotParse }
            parsed = p
            if let m = merchantOverride, !m.isEmpty { parsed.merchant = m }
        }
        if parsed.merchant.isEmpty { parsed.merchant = "未命名" }

        // 帳戶：指定名稱 → 卡號末四碼 → 預設帳戶 → 第一個帳戶
        let accounts = Store.accounts()
        var account: Account?
        if let name = accountName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            account = accounts.first { $0.name == name } ?? accounts.first { $0.name.localizedCaseInsensitiveContains(name) }
        }
        if account == nil, !parsed.cardLast4.isEmpty {
            account = accounts.first { !$0.cardLast4.isEmpty && $0.cardLast4 == parsed.cardLast4 }
        }
        if account == nil {
            // 捷徑傳來的卡片名稱（例如「台新 VISA 金融卡」）裡有帳戶名稱
            let flat = text.replacingOccurrences(of: " ", with: "").lowercased()
            account = accounts
                .filter { !$0.archived && $0.name.count >= 2 && flat.contains($0.name.replacingOccurrences(of: " ", with: "").lowercased()) }
                .max { $0.name.count < $1.name.count }
        }
        if account == nil {
            account = Store.account(id: Prefs.defaultAccountID) ?? accounts.first
        }

        // 分類
        let pool = cats.filter { $0.isIncome == parsed.isIncome }
        let category = pool.first { $0.name == parsed.categoryName }
            ?? pool.first { !parsed.categoryName.isEmpty && (parsed.categoryName.contains($0.name) || $0.name.contains(parsed.categoryName)) }
            ?? Learned.category(for: parsed.merchant, in: pool, requireConsistent: false)
            ?? pool.first { $0.name == (parsed.isIncome ? "其他收入" : "其他") }
            ?? pool.last

        // 外幣：換算成帳戶幣別，原始金額寫在備註
        var amount = parsed.amount
        var note = ""
        let accCurrency = account?.currency ?? Prefs.mainCurrency
        if parsed.currency != accCurrency {
            if !QuoteService.hasRate(from: parsed.currency, to: accCurrency) {
                await QuoteService.updateRates(for: [parsed.currency])
            }
            let rate = QuoteService.rate(from: parsed.currency, to: accCurrency)
            note = "原始金額 \(parsed.currency) \(Money.format(parsed.amount, currency: parsed.currency))"
            amount = (parsed.amount * rate * 100).rounded() / 100
        }

        // 重複通知（自動化有時會觸發兩次）
        let since = date.addingTimeInterval(-180)
        let recent = (try? ctx.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.createdAt > since }))) ?? []
        if let dup = recent.first(where: { $0.rawText == text && !text.isEmpty }) {
            return Result(entry: dup, duplicate: true, summary: "這則通知已經記過了：\(dup.title) \(Money.format(dup.amount))")
        }

        let entry = Entry(title: parsed.merchant, amount: amount, kind: parsed.isIncome ? .income : .expense,
                          date: date, category: category, account: account, note: note, source: .shortcut)
        entry.rawText = text.isEmpty ? nil : text
        entry.payMethod = PayMethod.detect(in: text)
        if !parsed.guess.isEmpty {
            entry.note = entry.note.isEmpty ? "推測：\(parsed.guess)" : "推測：\(parsed.guess)\n\(entry.note)"
        }
        ctx.insert(entry)
        // 捷徑文字附了位置：找出是哪一家分店
        await BranchMatcher.apply(to: entry, text: text, aiPlace: parsed.place)
        try ctx.save()

        let sign = parsed.isIncome ? "+" : "-"
        let summary = "已記帳：\(entry.branch ?? entry.title) \(sign)\(Money.format(amount, currency: accCurrency))（\(category?.name ?? "未分類")・\(account?.name ?? "未指定帳戶")）" + (parsed.usedAI ? "" : "\n（未使用 Apple Intelligence，用規則辨識）")
        return Result(entry: entry, duplicate: false, summary: summary)
    }
}

/// 用過去的紀錄猜分類：同商家上次用的分類。
/// requireConsistent：同一家店以前分過不同類（例如全家有時早餐有時零食）就不直接套用，交給 Apple Intelligence 看時間判斷
@MainActor
enum Learned {
    static func category(for merchant: String, in pool: [Category], requireConsistent: Bool = true) -> Category? {
        guard !merchant.isEmpty else { return nil }
        let ctx = Store.context
        var d = FetchDescriptor<Entry>(predicate: #Predicate { $0.title == merchant }, sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = 5
        let hits = (try? ctx.fetch(d)) ?? []
        if requireConsistent {
            let ids = Set(hits.compactMap { $0.category?.id })
            if ids.count > 1 { return nil }
        }
        for e in hits {
            if let c = e.category, pool.contains(where: { $0.id == c.id }) { return c }
        }
        return nil
    }
}
