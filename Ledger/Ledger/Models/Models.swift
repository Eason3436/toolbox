import Foundation
import SwiftData
import SwiftUI

// MARK: - 帳戶

enum AccountKind: String, CaseIterable, Identifiable, Codable {
    case debit, credit, cash, ewallet, saving

    var id: String { rawValue }

    var label: String {
        switch self {
        case .debit: "簽帳金融卡"
        case .credit: "信用卡"
        case .cash: "現金"
        case .ewallet: "電子支付"
        case .saving: "存款帳戶"
        }
    }

    var symbol: String {
        switch self {
        case .debit: "creditcard.fill"
        case .credit: "creditcard.and.123"
        case .cash: "banknote.fill"
        case .ewallet: "iphone.gen3"
        case .saving: "building.columns.fill"
        }
    }
}

@Model
final class Account {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = AccountKind.debit.rawValue
    var currency: String = "TWD"
    var colorHex: String = "#2C2C2E"
    var initialBalance: Double = 0
    /// 卡號末四碼，用來比對銀行通知
    var cardLast4: String = ""
    var order: Int = 0
    var archived: Bool = false
    var createdAt: Date = Date.now
    var cashewID: String?

    @Relationship(deleteRule: .nullify, inverse: \Entry.account)
    var entries: [Entry]? = []

    @Relationship(deleteRule: .nullify, inverse: \Entry.toAccount)
    var incomingTransfers: [Entry]? = []

    init(name: String, kind: AccountKind = .debit, currency: String = "TWD", colorHex: String = "#2C2C2E", initialBalance: Double = 0, order: Int = 0) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.currency = currency
        self.colorHex = colorHex
        self.initialBalance = initialBalance
        self.order = order
        self.createdAt = .now
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .debit }
        set { kindRaw = newValue.rawValue }
    }

    var color: Color { Color(hex: colorHex) }

    /// 截至某時間的餘額（不含該時間之後的交易）
    func balance(before date: Date? = nil) -> Double {
        var total = initialBalance
        for e in entries ?? [] where date == nil || e.date < date! {
            total += e.signedAmount(for: self)
        }
        for e in incomingTransfers ?? [] where date == nil || e.date < date! {
            total += e.signedAmount(for: self)
        }
        return total
    }

    var balance: Double { balance() }
}

// MARK: - 分類

@Model
final class Category {
    var id: UUID = UUID()
    var name: String = ""
    var symbol: String = "tag.fill"
    var emoji: String?
    var colorHex: String = "#8E8E93"
    var isIncome: Bool = false
    var order: Int = 0
    var cashewID: String?

    @Relationship(deleteRule: .nullify, inverse: \Entry.category)
    var entries: [Entry]? = []

    @Relationship(deleteRule: .nullify, inverse: \Bill.category)
    var bills: [Bill]? = []

    /// 子分類的主分類
    var parent: Category?

    @Relationship(deleteRule: .cascade, inverse: \Category.parent)
    var children: [Category]? = []

    @Relationship(deleteRule: .nullify, inverse: \Budget.categories)
    var budgets: [Budget]? = []

    init(name: String, symbol: String, colorHex: String, isIncome: Bool = false, order: Int = 0) {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.isIncome = isIncome
        self.order = order
    }

    var color: Color { Color(hex: colorHex) }

    /// 統計用的主分類
    var main: Category { parent ?? self }

    var isSub: Bool { parent != nil }

    var sortedChildren: [Category] { (children ?? []).sorted { $0.order < $1.order } }

    var fullName: String { parent.map { "\($0.name) › \(name)" } ?? name }
}

// MARK: - 交易

enum EntryKind: String, CaseIterable, Identifiable, Codable {
    case expense, income, transfer
    var id: String { rawValue }
    var label: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "轉帳"
        }
    }
}

enum EntrySource: String, Codable {
    case manual, shortcut, cashew, bill
}

@Model
final class Entry {
    var id: UUID = UUID()
    var title: String = ""
    /// 永遠是正數，正負由 kind 決定
    var amount: Double = 0
    var kindRaw: String = EntryKind.expense.rawValue
    var date: Date = Date.now
    var note: String = ""
    var sourceRaw: String = EntrySource.manual.rawValue
    /// 捷徑送進來的原始通知
    var rawText: String?
    var billKey: String?
    var cashewID: String?
    var createdAt: Date = Date.now

    var excludeFromBudget: Bool = false

    var category: Category?
    var account: Account?
    var toAccount: Account?
    var bill: Bill?
    var goal: Goal?

    init(title: String, amount: Double, kind: EntryKind, date: Date = .now, category: Category? = nil, account: Account? = nil, note: String = "", source: EntrySource = .manual) {
        self.id = UUID()
        self.title = title
        self.amount = abs(amount)
        self.kindRaw = kind.rawValue
        self.date = date
        self.category = category
        self.account = account
        self.note = note
        self.sourceRaw = source.rawValue
        self.createdAt = .now
    }

    var kind: EntryKind {
        get { EntryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var source: EntrySource { EntrySource(rawValue: sourceRaw) ?? .manual }

    /// 對整體收支的影響（轉帳為 0）
    var signedAmount: Double {
        switch kind {
        case .expense: -amount
        case .income: amount
        case .transfer: 0
        }
    }

    /// 對某個帳戶餘額的影響
    func signedAmount(for acc: Account) -> Double {
        switch kind {
        case .expense: return account?.id == acc.id ? -amount : 0
        case .income: return account?.id == acc.id ? amount : 0
        case .transfer:
            var v = 0.0
            if account?.id == acc.id { v -= amount }
            if toAccount?.id == acc.id { v += amount }
            return v
        }
    }
}

// MARK: - 帳單 / 訂閱

enum Recurrence: String, CaseIterable, Identifiable, Codable {
    case weekly, monthly, yearly, once
    var id: String { rawValue }
    var label: String {
        switch self {
        case .weekly: "每週"
        case .monthly: "每月"
        case .yearly: "每年"
        case .once: "一次"
        }
    }
}

@Model
final class Bill {
    var id: UUID = UUID()
    var name: String = ""
    var amount: Double = 0
    var currency: String = "TWD"
    var recurrenceRaw: String = Recurrence.monthly.rawValue
    /// 第一次到期日，之後依週期推算
    var anchorDate: Date = Date.now
    var endDate: Date?
    var autoPay: Bool = false
    var platform: String = ""
    var note: String = ""
    var isSubscription: Bool = true
    /// 已繳的期別（yyyy-MM-dd）
    var paidKeys: [String] = []
    var active: Bool = true
    var createdAt: Date = Date.now
    var cashewID: String?

    var category: Category?
    var account: Account?

    @Relationship(deleteRule: .nullify, inverse: \Entry.bill)
    var payments: [Entry]? = []

    init(name: String, amount: Double, recurrence: Recurrence = .monthly, anchorDate: Date = .now) {
        self.id = UUID()
        self.name = name
        self.amount = amount
        self.recurrenceRaw = recurrence.rawValue
        self.anchorDate = Calendar.current.startOfDay(for: anchorDate)
        self.createdAt = .now
    }

    var recurrence: Recurrence {
        get { Recurrence(rawValue: recurrenceRaw) ?? .monthly }
        set { recurrenceRaw = newValue.rawValue }
    }

    var dayOfMonth: Int { Calendar.current.component(.day, from: anchorDate) }

    var recurrenceText: String {
        let cal = Calendar.current
        switch recurrence {
        case .monthly: return "每月\(dayOfMonth)日"
        case .yearly: return "每年\(cal.component(.month, from: anchorDate))月\(dayOfMonth)日"
        case .weekly:
            let wd = cal.component(.weekday, from: anchorDate)
            return "每週" + ["日", "一", "二", "三", "四", "五", "六"][wd - 1]
        case .once: return "單次"
        }
    }

    /// 某段期間內的到期日
    func dueDates(in interval: DateInterval) -> [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: anchorDate)
        var result: [Date] = []
        if let end = endDate, end < interval.start { return [] }
        switch recurrence {
        case .once:
            if interval.contains(start) { result.append(start) }
        case .weekly:
            var d = start
            if d < interval.start {
                let weeks = Int(interval.start.timeIntervalSince(d) / (7 * 86400))
                d = cal.date(byAdding: .day, value: weeks * 7, to: d) ?? d
            }
            while d < interval.end {
                if d >= interval.start { result.append(d) }
                d = cal.date(byAdding: .day, value: 7, to: d) ?? interval.end
            }
        case .monthly, .yearly:
            let stepMonths = recurrence == .monthly ? 1 : 12
            let day = cal.component(.day, from: start)
            var i = 0
            while i < 2400 {
                guard let monthStart = cal.date(byAdding: .month, value: i * stepMonths, to: cal.date(from: cal.dateComponents([.year, .month], from: start))!) else { break }
                if monthStart >= interval.end { break }
                let range = cal.range(of: .day, in: .month, for: monthStart) ?? 1..<29
                let d = cal.date(byAdding: .day, value: min(day, range.count) - 1, to: monthStart)!
                if interval.contains(d) && d >= start { result.append(d) }
                i += 1
            }
        }
        if let end = endDate { result = result.filter { $0 <= end } }
        return result
    }

    static func key(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func isPaid(_ due: Date) -> Bool { paidKeys.contains(Bill.key(for: due)) }
}

// MARK: - 資產

enum AssetGroup: String, CaseIterable, Identifiable, Codable {
    case finance, cash, property, other, liability

    var id: String { rawValue }

    var label: String {
        switch self {
        case .finance: "金融"
        case .cash: "現金"
        case .property: "不動產"
        case .other: "其他"
        case .liability: "負債"
        }
    }

    var symbol: String {
        switch self {
        case .finance: "chart.line.uptrend.xyaxis"
        case .cash: "banknote"
        case .property: "house.fill"
        case .other: "shippingbox.fill"
        case .liability: "creditcard.trianglebadge.exclamationmark"
        }
    }

    var colorHex: String {
        switch self {
        case .finance: "#2F7D32"
        case .cash: "#A0522D"
        case .property: "#2D5DA0"
        case .other: "#6A4C9C"
        case .liability: "#B3261E"
        }
    }

    var color: Color { Color(hex: colorHex) }
}

enum AssetKind: String, CaseIterable, Identifiable, Codable {
    case stock, etf, fund, crypto, deposit, cash, property, other, loan
    var id: String { rawValue }

    var label: String {
        switch self {
        case .stock: "股票"
        case .etf: "ETF"
        case .fund: "基金"
        case .crypto: "加密貨幣"
        case .deposit: "定存"
        case .cash: "現金"
        case .property: "不動產"
        case .other: "其他"
        case .loan: "貸款"
        }
    }

    var group: AssetGroup {
        switch self {
        case .stock, .etf, .fund, .crypto, .deposit: .finance
        case .cash: .cash
        case .property: .property
        case .other: .other
        case .loan: .liability
        }
    }

    var supportsQuote: Bool { [.stock, .etf, .fund, .crypto].contains(self) }

    var symbol: String {
        switch self {
        case .stock: "chart.line.uptrend.xyaxis"
        case .etf: "chart.pie.fill"
        case .fund: "chart.bar.fill"
        case .crypto: "bitcoinsign.circle.fill"
        case .deposit: "building.columns.fill"
        case .cash: "banknote.fill"
        case .property: "house.fill"
        case .other: "tag.fill"
        case .loan: "creditcard.trianglebadge.exclamationmark"
        }
    }
}

@Model
final class Asset {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = AssetKind.stock.rawValue
    /// 報價代號，例如 2330.TW、AAPL、BTC-USD
    var ticker: String = ""
    var quantity: Double = 0
    /// 平均成本（每單位）
    var costPerUnit: Double = 0
    /// 沒有自動報價時的手動市值
    var manualValue: Double = 0
    var currency: String = "TWD"
    var autoQuote: Bool = true
    var lastPrice: Double = 0
    var previousClose: Double = 0
    var priceUpdatedAt: Date?
    var note: String = ""
    var order: Int = 0
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \AssetLot.asset)
    var lots: [AssetLot]? = []

    init(name: String, kind: AssetKind, ticker: String = "", quantity: Double = 0, manualValue: Double = 0, currency: String = "TWD") {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.ticker = ticker
        self.quantity = quantity
        self.manualValue = manualValue
        self.currency = currency
        self.autoQuote = kind.supportsQuote && !ticker.isEmpty
        self.createdAt = .now
    }

    var kind: AssetKind {
        get { AssetKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var usesQuote: Bool { autoQuote && kind.supportsQuote && !ticker.isEmpty }

    /// 以資產本身幣別計算的市值
    var nativeValue: Double {
        let v = usesQuote ? quantity * lastPrice : manualValue
        return kind == .loan ? -abs(v) : v
    }

    var dayChangeRatio: Double? {
        guard usesQuote, previousClose > 0, lastPrice > 0 else { return nil }
        return (lastPrice - previousClose) / previousClose
    }

    var profitRatio: Double? {
        guard usesQuote, costPerUnit > 0, lastPrice > 0 else { return nil }
        return (lastPrice - costPerUnit) / costPerUnit
    }

    var sortedLots: [AssetLot] { (lots ?? []).sorted { $0.date > $1.date } }

    /// 依買賣紀錄重算持股數與平均成本（平均成本法）
    func recomputeFromLots() {
        let list = (lots ?? []).sorted { $0.date < $1.date }
        guard !list.isEmpty else { return }
        var qty = 0.0
        var cost = 0.0
        for lot in list {
            if lot.quantity >= 0 {
                cost += lot.quantity * lot.price + lot.fee
                qty += lot.quantity
            } else {
                let sell = min(-lot.quantity, qty)
                let avg = qty > 0 ? cost / qty : 0
                cost -= avg * sell
                qty -= sell
            }
        }
        quantity = qty
        costPerUnit = qty > 0 ? cost / qty : 0
    }
}

/// 一筆買入或賣出（數量為負代表賣出）
@Model
final class AssetLot {
    var id: UUID = UUID()
    var date: Date = Date.now
    var quantity: Double = 0
    var price: Double = 0
    var fee: Double = 0
    var note: String = ""
    var asset: Asset?

    init(date: Date, quantity: Double, price: Double, fee: Double = 0) {
        self.id = UUID()
        self.date = date
        self.quantity = quantity
        self.price = price
        self.fee = fee
    }

    var isBuy: Bool { quantity >= 0 }
}

// MARK: - 顏色

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.hasPrefix("0X") { s.removeFirst(2) }
        if s.count == 8 { s.removeFirst(2) } // ARGB → RGB
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
}
