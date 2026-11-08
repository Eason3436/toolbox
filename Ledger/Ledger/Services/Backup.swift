import Foundation
import SwiftData
import UniformTypeIdentifiers

/// 從「分享」或「檔案」打開的檔案
@MainActor
enum FileImport {
    static func handle(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        do {
            if ext == "json" {
                let n = try Backup.restore(from: url)
                return "已從備份還原 \(n) 筆資料"
            }
            let report = try CashewImporter.importBackup(at: url)
            return report.text
        } catch {
            return error.localizedDescription
        }
    }
}

/// App 自己的 JSON 備份（合併還原，不會刪除現有資料）
@MainActor
enum Backup {
    struct AccountDTO: Codable { var id: UUID; var name: String; var kind: String; var currency: String; var color: String; var initial: Double; var last4: String; var order: Int; var archived: Bool }
    struct CategoryDTO: Codable { var id: UUID; var name: String; var symbol: String; var emoji: String?; var color: String; var income: Bool; var order: Int; var parent: UUID? }
    struct EntryDTO: Codable { var id: UUID; var title: String; var amount: Double; var kind: String; var date: Date; var note: String; var source: String; var raw: String?; var billKey: String?; var exclude: Bool; var category: UUID?; var account: UUID?; var toAccount: UUID?; var bill: UUID?; var goal: UUID?; var pay: String? = nil; var receipt: String? = nil; var branch: String? = nil; var branchAddress: String? = nil; var lat: Double? = nil; var lon: Double? = nil }
    struct BillDTO: Codable { var id: UUID; var name: String; var amount: Double; var currency: String; var recurrence: String; var anchor: Date; var end: Date?; var autoPay: Bool; var platform: String; var note: String; var subscription: Bool; var income: Bool?; var paid: [String]; var active: Bool; var category: UUID?; var account: UUID? }
    struct AssetDTO: Codable { var id: UUID; var name: String; var kind: String; var ticker: String; var quantity: Double; var cost: Double; var manual: Double; var currency: String; var auto: Bool; var price: Double; var prev: Double; var note: String; var order: Int; var lots: [LotDTO] }
    struct LotDTO: Codable { var id: UUID; var date: Date; var quantity: Double; var price: Double; var fee: Double; var note: String }
    struct BudgetDTO: Codable { var id: UUID; var name: String; var amount: Double; var period: String; var color: String; var pinned: Bool; var archived: Bool; var order: Int; var categories: [UUID] }
    struct GoalDTO: Codable { var id: UUID; var name: String; var target: Double; var symbol: String; var color: String; var end: Date?; var archived: Bool; var order: Int }
    struct LoanDTO: Codable { var id: UUID; var person: String; var amount: Double; var direction: String; var date: Date; var due: Date?; var note: String; var currency: String; var records: [LoanRecord]; var closed: Bool }

    struct File: Codable {
        var version = 1
        var exportedAt = Date.now
        var accounts: [AccountDTO] = []
        var categories: [CategoryDTO] = []
        var entries: [EntryDTO] = []
        var bills: [BillDTO] = []
        var assets: [AssetDTO] = []
        var budgets: [BudgetDTO] = []
        var goals: [GoalDTO] = []
        var loans: [LoanDTO] = []
    }

    static func export() throws -> URL {
        let ctx = Store.context
        var f = File()
        f.accounts = ((try? ctx.fetch(FetchDescriptor<Account>())) ?? []).map {
            AccountDTO(id: $0.id, name: $0.name, kind: $0.kindRaw, currency: $0.currency, color: $0.colorHex, initial: $0.initialBalance, last4: $0.cardLast4, order: $0.order, archived: $0.archived)
        }
        f.categories = ((try? ctx.fetch(FetchDescriptor<Category>())) ?? []).map {
            CategoryDTO(id: $0.id, name: $0.name, symbol: $0.symbol, emoji: $0.emoji, color: $0.colorHex, income: $0.isIncome, order: $0.order, parent: $0.parent?.id)
        }
        f.entries = ((try? ctx.fetch(FetchDescriptor<Entry>())) ?? []).map {
            EntryDTO(id: $0.id, title: $0.title, amount: $0.amount, kind: $0.kindRaw, date: $0.date, note: $0.note, source: $0.sourceRaw, raw: $0.rawText, billKey: $0.billKey, exclude: $0.excludeFromBudget,
                     category: $0.category?.id, account: $0.account?.id, toAccount: $0.toAccount?.id, bill: $0.bill?.id, goal: $0.goal?.id,
                     pay: $0.payMethod, receipt: $0.receiptJSON, branch: $0.branch, branchAddress: $0.branchAddress, lat: $0.latitude, lon: $0.longitude)
        }
        f.bills = ((try? ctx.fetch(FetchDescriptor<Bill>())) ?? []).map {
            BillDTO(id: $0.id, name: $0.name, amount: $0.amount, currency: $0.currency, recurrence: $0.recurrenceRaw, anchor: $0.anchorDate, end: $0.endDate, autoPay: $0.autoPay, platform: $0.platform, note: $0.note, subscription: $0.isSubscription, income: $0.isIncome, paid: $0.paidKeys, active: $0.active, category: $0.category?.id, account: $0.account?.id)
        }
        f.assets = ((try? ctx.fetch(FetchDescriptor<Asset>())) ?? []).map { a in
            AssetDTO(id: a.id, name: a.name, kind: a.kindRaw, ticker: a.ticker, quantity: a.quantity, cost: a.costPerUnit, manual: a.manualValue, currency: a.currency, auto: a.autoQuote, price: a.lastPrice, prev: a.previousClose, note: a.note, order: a.order,
                     lots: (a.lots ?? []).map { LotDTO(id: $0.id, date: $0.date, quantity: $0.quantity, price: $0.price, fee: $0.fee, note: $0.note) })
        }
        f.budgets = ((try? ctx.fetch(FetchDescriptor<Budget>())) ?? []).map {
            BudgetDTO(id: $0.id, name: $0.name, amount: $0.amount, period: $0.periodRaw, color: $0.colorHex, pinned: $0.pinned, archived: $0.archived, order: $0.order, categories: ($0.categories ?? []).map(\.id))
        }
        f.goals = ((try? ctx.fetch(FetchDescriptor<Goal>())) ?? []).map {
            GoalDTO(id: $0.id, name: $0.name, target: $0.target, symbol: $0.symbol, color: $0.colorHex, end: $0.endDate, archived: $0.archived, order: $0.order)
        }
        f.loans = ((try? ctx.fetch(FetchDescriptor<Loan>())) ?? []).map {
            LoanDTO(id: $0.id, person: $0.person, amount: $0.amount, direction: $0.directionRaw, date: $0.date, due: $0.dueDate, note: $0.note, currency: $0.currency, records: $0.records, closed: $0.closed)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(f)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("記帳備份-\(df.string(from: .now)).json")
        try data.write(to: url)
        return url
    }

    /// 依 id 合併：已存在的略過
    static func restore(from url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let f = try dec.decode(File.self, from: data)
        let ctx = Store.context
        var count = 0

        var accounts = Dictionary(((try? ctx.fetch(FetchDescriptor<Account>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for d in f.accounts where accounts[d.id] == nil {
            let a = Account(name: d.name, kind: AccountKind(rawValue: d.kind) ?? .debit, currency: d.currency, colorHex: d.color, initialBalance: d.initial, order: d.order)
            a.id = d.id; a.cardLast4 = d.last4; a.archived = d.archived
            ctx.insert(a); accounts[d.id] = a; count += 1
        }
        var cats = Dictionary(((try? ctx.fetch(FetchDescriptor<Category>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for d in f.categories where cats[d.id] == nil {
            let c = Category(name: d.name, symbol: d.symbol, colorHex: d.color, isIncome: d.income, order: d.order)
            c.id = d.id; c.emoji = d.emoji
            ctx.insert(c); cats[d.id] = c; count += 1
        }
        for d in f.categories { if let p = d.parent, let c = cats[d.id], c.parent == nil { c.parent = cats[p] } }

        var bills = Dictionary(((try? ctx.fetch(FetchDescriptor<Bill>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for d in f.bills where bills[d.id] == nil {
            let b = Bill(name: d.name, amount: d.amount, recurrence: Recurrence(rawValue: d.recurrence) ?? .monthly, anchorDate: d.anchor)
            b.id = d.id; b.currency = d.currency; b.endDate = d.end; b.autoPay = d.autoPay; b.platform = d.platform; b.note = d.note
            b.isSubscription = d.subscription; b.isIncome = d.income ?? false; b.paidKeys = d.paid; b.active = d.active
            b.category = d.category.flatMap { cats[$0] }; b.account = d.account.flatMap { accounts[$0] }
            ctx.insert(b); bills[d.id] = b; count += 1
        }
        var goals = Dictionary(((try? ctx.fetch(FetchDescriptor<Goal>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for d in f.goals where goals[d.id] == nil {
            let g = Goal(name: d.name, target: d.target)
            g.id = d.id; g.symbol = d.symbol; g.colorHex = d.color; g.endDate = d.end; g.archived = d.archived; g.order = d.order
            ctx.insert(g); goals[d.id] = g; count += 1
        }
        let entryIDs = Set(((try? ctx.fetch(FetchDescriptor<Entry>())) ?? []).map(\.id))
        for d in f.entries where !entryIDs.contains(d.id) {
            let e = Entry(title: d.title, amount: d.amount, kind: EntryKind(rawValue: d.kind) ?? .expense, date: d.date,
                          category: d.category.flatMap { cats[$0] }, account: d.account.flatMap { accounts[$0] }, note: d.note,
                          source: EntrySource(rawValue: d.source) ?? .manual)
            e.id = d.id; e.rawText = d.raw; e.billKey = d.billKey; e.excludeFromBudget = d.exclude
            e.toAccount = d.toAccount.flatMap { accounts[$0] }; e.bill = d.bill.flatMap { bills[$0] }; e.goal = d.goal.flatMap { goals[$0] }
            e.payMethod = d.pay; e.receiptJSON = d.receipt; e.branch = d.branch; e.branchAddress = d.branchAddress
            e.latitude = d.lat; e.longitude = d.lon
            ctx.insert(e); count += 1
        }
        let assetIDs = Set(((try? ctx.fetch(FetchDescriptor<Asset>())) ?? []).map(\.id))
        for d in f.assets where !assetIDs.contains(d.id) {
            let a = Asset(name: d.name, kind: AssetKind(rawValue: d.kind) ?? .other, ticker: d.ticker, quantity: d.quantity, manualValue: d.manual, currency: d.currency)
            a.id = d.id; a.costPerUnit = d.cost; a.autoQuote = d.auto; a.lastPrice = d.price; a.previousClose = d.prev; a.note = d.note; a.order = d.order
            ctx.insert(a)
            for l in d.lots {
                let lot = AssetLot(date: l.date, quantity: l.quantity, price: l.price, fee: l.fee)
                lot.id = l.id; lot.note = l.note; lot.asset = a
                ctx.insert(lot)
            }
            count += 1
        }
        let budgetIDs = Set(((try? ctx.fetch(FetchDescriptor<Budget>())) ?? []).map(\.id))
        for d in f.budgets where !budgetIDs.contains(d.id) {
            let b = Budget(name: d.name, amount: d.amount, period: BudgetPeriod(rawValue: d.period) ?? .monthly)
            b.id = d.id; b.colorHex = d.color; b.pinned = d.pinned; b.archived = d.archived; b.order = d.order
            b.categories = d.categories.compactMap { cats[$0] }
            ctx.insert(b); count += 1
        }
        let loanIDs = Set(((try? ctx.fetch(FetchDescriptor<Loan>())) ?? []).map(\.id))
        for d in f.loans where !loanIDs.contains(d.id) {
            let l = Loan(person: d.person, amount: d.amount, direction: LoanDirection(rawValue: d.direction) ?? .lent)
            l.id = d.id; l.date = d.date; l.dueDate = d.due; l.note = d.note; l.currency = d.currency; l.records = d.records; l.closed = d.closed
            ctx.insert(l); count += 1
        }
        try ctx.save()
        return count
    }

    /// 交易匯出成 CSV（Excel／Numbers 可開）
    static func exportCSV() throws -> URL {
        let entries = (try? Store.context.fetch(FetchDescriptor<Entry>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        func esc(_ s: String) -> String {
            s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = ["日期,類型,名稱,金額,分類,子分類,帳戶,轉入帳戶,備註"]
        for e in entries {
            let main = e.category?.main.name ?? ""
            let sub = e.category?.isSub == true ? e.category!.name : ""
            lines.append([f.string(from: e.date), e.kind.label, esc(e.title), String(e.signedAmount == 0 ? e.amount : e.signedAmount),
                          esc(main), esc(sub), esc(e.account?.name ?? ""), esc(e.toAccount?.name ?? ""), esc(e.note)].joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("記帳交易.csv")
        // 加 BOM 讓 Excel 正確顯示中文
        try ("\u{FEFF}" + lines.joined(separator: "\n")).data(using: .utf8)!.write(to: url)
        return url
    }
}
