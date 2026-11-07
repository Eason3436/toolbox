import Foundation
import SQLite3
import SwiftData

/// 讀取 Cashew 匯出的備份檔（設定 → 備份 → 匯出資料，檔名 cashew-xxxx.sql，實際是 SQLite 資料庫）
@MainActor
enum CashewImporter {
    struct Report {
        var accounts = 0
        var categories = 0
        var entries = 0
        var bills = 0
        var skipped = 0

        var text: String {
            "匯入 \(accounts) 個帳戶、\(categories) 個分類、\(entries) 筆交易、\(bills) 個帳單／訂閱" + (skipped > 0 ? "（略過 \(skipped) 筆已存在的資料）" : "")
        }
    }

    enum ImportError: LocalizedError {
        case cannotOpen
        case notCashew
        var errorDescription: String? {
            switch self {
            case .cannotOpen: "無法開啟檔案"
            case .notCashew: "這不是 Cashew 的備份檔（找不到 transactions 資料表）"
            }
        }
    }

    private typealias Row = [String: Any]

    static func importBackup(at url: URL) throws -> Report {
        // 先複製到暫存資料夾，避免直接讀 iCloud 或其他 App 的檔案
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cashew-import-\(UUID().uuidString).sqlite")
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: url, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw ImportError.cannotOpen }
        defer { sqlite3_close(db) }

        let tables = Set(query(db, "SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] as? String })
        guard tables.contains("transactions") else { throw ImportError.notCashew }

        let ctx = Store.context
        var report = Report()

        // 已存在的資料（重複匯入時略過）
        let existingAccounts = (try? ctx.fetch(FetchDescriptor<Account>())) ?? []
        let existingCategories = (try? ctx.fetch(FetchDescriptor<Category>())) ?? []
        let existingEntryIDs = Set(((try? ctx.fetch(FetchDescriptor<Entry>())) ?? []).compactMap(\.cashewID))
        let existingBillIDs = Set(((try? ctx.fetch(FetchDescriptor<Bill>())) ?? []).compactMap(\.cashewID))

        // 帳戶
        var accountMap: [String: Account] = [:]
        for a in existingAccounts { if let cid = a.cashewID { accountMap[cid] = a } }
        let maxOrder = existingAccounts.map(\.order).max() ?? 0
        if tables.contains("wallets") {
            for (i, w) in query(db, "SELECT * FROM wallets ORDER BY \"order\"").enumerated() {
                let pk = str(w["wallet_pk"])
                if accountMap[pk] != nil { report.skipped += 1; continue }
                let name = str(w["name"])
                let currency = str(w["currency"]).uppercased()
                let acc = Account(name: name.isEmpty ? "Cashew 帳戶" : name,
                                  kind: name.contains("現金") || name.lowercased().contains("cash") ? .cash : .debit,
                                  currency: currency.isEmpty ? Prefs.mainCurrency : currency,
                                  colorHex: colorHex(w["colour"]) ?? "#2C2C2E",
                                  order: maxOrder + 1 + i)
                acc.cashewID = pk
                ctx.insert(acc)
                accountMap[pk] = acc
                report.accounts += 1
            }
        }

        // 分類（子分類併入主分類）
        var categoryMap: [String: Category] = [:]
        for c in existingCategories { if let cid = c.cashewID { categoryMap[cid] = c } }
        var subToMain: [String: String] = [:]
        if tables.contains("categories") {
            let rows = query(db, "SELECT * FROM categories ORDER BY \"order\"")
            let catOrder = existingCategories.map(\.order).max() ?? 0
            for (i, c) in rows.enumerated() {
                let pk = str(c["category_pk"])
                if let main = c["main_category_pk"] as? String, !main.isEmpty {
                    subToMain[pk] = main
                    continue
                }
                if categoryMap[pk] != nil { continue }
                let name = str(c["name"])
                let income = bool(c["income"])
                // 名稱相同的分類直接合併
                if let same = existingCategories.first(where: { $0.name == name && $0.isIncome == income }) {
                    same.cashewID = same.cashewID ?? pk
                    categoryMap[pk] = same
                    continue
                }
                let cat = Category(name: name.isEmpty ? "未命名" : name,
                                   symbol: symbol(forCashewIcon: str(c["icon_name"]), name: name),
                                   colorHex: colorHex(c["colour"]) ?? "#8E8E93",
                                   isIncome: income, order: catOrder + 1 + i)
                if let emoji = c["emoji_icon_name"] as? String, !emoji.isEmpty { cat.emoji = emoji }
                cat.cashewID = pk
                ctx.insert(cat)
                categoryMap[pk] = cat
                report.categories += 1
            }
        }
        func category(_ pk: String, sub: String?) -> Category? {
            if let c = categoryMap[pk] { return c }
            if let main = subToMain[pk] { return categoryMap[main] }
            if let sub, let main = subToMain[sub] { return categoryMap[main] }
            return nil
        }

        // 交易與訂閱
        let rows = query(db, "SELECT * FROM transactions ORDER BY date_created")
        var seenBills: Set<String> = []
        for t in rows {
            let pk = str(t["transaction_pk"])
            let amountRaw = double(t["amount"])
            let type = t["type"] as? Int64 // 0 upcoming, 1 subscription, 2 repetitive, 3 credit, 4 debt
            let paid = bool(t["paid"])
            let name = str(t["name"])
            let date = dateValue(t["date_created"]) ?? .now
            let cat = category(str(t["category_fk"]), sub: t["sub_category_fk"] as? String)
            let acc = accountMap[str(t["wallet_fk"])]

            // 尚未付款的訂閱／重複付款 → 帳單
            if let type, (type == 1 || type == 2), !paid {
                let key = "\(name)|\(abs(amountRaw))"
                if seenBills.contains(key) || existingBillIDs.contains(pk) { continue }
                seenBills.insert(key)
                let reocc = t["reoccurrence"] as? Int64 ?? 3
                let recurrence: Recurrence = switch reocc {
                case 2: .weekly
                case 4: .yearly
                case 1: .weekly
                default: .monthly
                }
                let bill = Bill(name: name.isEmpty ? "訂閱" : name, amount: abs(amountRaw), recurrence: recurrence, anchorDate: date)
                bill.isSubscription = type == 1
                bill.category = cat
                bill.account = acc
                bill.currency = acc?.currency ?? Prefs.mainCurrency
                bill.note = str(t["note"])
                bill.cashewID = pk
                ctx.insert(bill)
                report.bills += 1
                continue
            }
            // 未付款的一次性預定交易略過
            if let type, type == 0, !paid { continue }

            if existingEntryIDs.contains(pk) { report.skipped += 1; continue }
            let isIncome = amountRaw > 0
            let entry = Entry(title: name.isEmpty ? (cat?.name ?? "交易") : name,
                              amount: abs(amountRaw), kind: isIncome ? .income : .expense,
                              date: date, category: cat, account: acc, note: str(t["note"]), source: .cashew)
            entry.cashewID = pk
            ctx.insert(entry)
            report.entries += 1
        }

        try ctx.save()
        return report
    }

    // MARK: SQLite 小工具

    private static func query(_ db: OpaquePointer, _ sql: String) -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: Row = [:]
            for i in 0..<n {
                let name = String(cString: sqlite3_column_name(stmt, i)!)
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(stmt, i) { row[name] = String(cString: c) }
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static func str(_ v: Any?) -> String {
        switch v {
        case let s as String: s
        case let i as Int64: String(i)
        case let d as Double: String(d)
        default: ""
        }
    }

    private static func double(_ v: Any?) -> Double {
        switch v {
        case let d as Double: d
        case let i as Int64: Double(i)
        case let s as String: Double(s) ?? 0
        default: 0
        }
    }

    private static func bool(_ v: Any?) -> Bool {
        switch v {
        case let i as Int64: i != 0
        case let s as String: s == "1" || s.lowercased() == "true"
        default: false
        }
    }

    /// drift 預設把時間存成 Unix 秒數；也支援文字格式
    private static func dateValue(_ v: Any?) -> Date? {
        switch v {
        case let i as Int64:
            // 毫秒或秒
            return i > 100_000_000_000 ? Date(timeIntervalSince1970: Double(i) / 1000) : Date(timeIntervalSince1970: Double(i))
        case let d as Double:
            return Date(timeIntervalSince1970: d)
        case let s as String:
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: s) { return d }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
                f.dateFormat = fmt
                if let d = f.date(from: s) { return d }
            }
            return nil
        default:
            return nil
        }
    }

    /// Cashew 的顏色是 "0xffRRGGBB"
    private static func colorHex(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        var hex = s.lowercased().replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "#", with: "")
        if hex.count == 8 { hex.removeFirst(2) }
        guard hex.count == 6 else { return nil }
        return "#" + hex.uppercased()
    }

    private static func symbol(forCashewIcon icon: String, name: String) -> String {
        let key = icon.replacingOccurrences(of: ".png", with: "").lowercased()
        let map: [String: String] = [
            "cutlery": "fork.knife", "restaurant": "fork.knife", "food": "fork.knife", "coffee": "cup.and.saucer.fill",
            "groceries": "cart.fill", "shopping": "bag.fill", "shopping-bag": "bag.fill", "cart": "cart.fill",
            "car": "car.fill", "bus": "bus.fill", "train": "tram.fill", "plane": "airplane", "fuel": "fuelpump.fill", "taxi": "car.fill",
            "house": "house.fill", "home": "house.fill", "bills": "doc.text.fill", "electricity": "bolt.fill", "water": "drop.fill",
            "wifi": "wifi", "phone": "iphone", "gift": "gift.fill", "gifts": "gift.fill", "health": "cross.case.fill",
            "medical": "stethoscope", "pill": "pills.fill", "gym": "dumbbell.fill", "sport": "sportscourt.fill",
            "entertainment": "gamecontroller.fill", "game": "gamecontroller.fill", "movie": "film.fill", "music": "music.note",
            "education": "book.fill", "book": "book.fill", "pet": "pawprint.fill", "beauty": "sparkles", "clothes": "tshirt.fill",
            "salary": "banknote.fill", "money": "banknote.fill", "cash": "banknote.fill", "investment": "chart.line.uptrend.xyaxis",
            "work": "briefcase.fill", "travel": "airplane", "subscription": "arrow.triangle.2.circlepath",
        ]
        if let s = map[key] { return s }
        for (k, s) in map where key.contains(k) || name.lowercased().contains(k) { return s }
        return "tag.fill"
    }
}
