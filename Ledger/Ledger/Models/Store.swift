import Foundation
import SwiftData

/// 整個 App（含捷徑動作）共用同一個資料庫
@MainActor
enum Store {
    static let container: ModelContainer = {
        let schema = Schema([Account.self, Category.self, Entry.self, Bill.self, Asset.self, AssetLot.self, Budget.self, Goal.self, Loan.self])
        let config = ModelConfiguration("Ledger", schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("無法開啟資料庫：\(error)")
        }
    }()

    static var context: ModelContext { container.mainContext }

    /// 第一次開啟時放入預設分類與帳戶
    static func seedIfNeeded() {
        let ctx = context
        let catCount = (try? ctx.fetchCount(FetchDescriptor<Category>())) ?? 0
        if catCount == 0 {
            let defaults: [(String, String, String, Bool)] = [
                ("餐飲", "fork.knife", "#F2A93B", false),
                ("交通", "car.fill", "#34A853", false),
                ("購物", "bag.fill", "#4C7BF4", false),
                ("居家", "house.fill", "#3478F6", false),
                ("網路", "wifi", "#5E4BD8", false),
                ("訂閱", "arrow.triangle.2.circlepath", "#D9653B", false),
                ("醫療", "cross.case.fill", "#E5484D", false),
                ("娛樂", "sparkles.tv.fill", "#B83280", false),
                ("日用品", "basket.fill", "#8D6E63", false),
                ("其他", "square.grid.2x2.fill", "#8E8E93", false),
                ("薪水", "banknote.fill", "#2F7D32", true),
                ("投資", "chart.line.uptrend.xyaxis", "#1B8A5A", true),
                ("退款", "arrow.uturn.backward", "#607D8B", true),
                ("其他收入", "plus.circle.fill", "#8E8E93", true),
            ]
            for (i, d) in defaults.enumerated() {
                ctx.insert(Category(name: d.0, symbol: d.1, colorHex: d.2, isIncome: d.3, order: i))
            }
        }
        let accCount = (try? ctx.fetchCount(FetchDescriptor<Account>())) ?? 0
        if accCount == 0 {
            ctx.insert(Account(name: "現金", kind: .cash, colorHex: "#A0522D", order: 0))
            ctx.insert(Account(name: "簽帳金融卡", kind: .debit, colorHex: "#2C2C2E", order: 1))
        }
        try? ctx.save()
    }

    static func categories(income: Bool? = nil) -> [Category] {
        let all = (try? context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.order)]))) ?? []
        guard let income else { return all }
        return all.filter { $0.isIncome == income }
    }

    static func accounts() -> [Account] {
        ((try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.order)]))) ?? []).filter { !$0.archived }
    }

    static func account(id: String?) -> Account? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return accounts().first { $0.id == uuid }
    }
}

/// 使用者偏好（UserDefaults）
enum Prefs {
    static let mainCurrencyKey = "mainCurrency"
    static let hideAmountsKey = "hideAmounts"
    static let defaultAccountKey = "defaultAccountID"
    static let selectedAccountKey = "selectedAccountID"

    static var mainCurrency: String {
        UserDefaults.standard.string(forKey: mainCurrencyKey) ?? "TWD"
    }

    static var defaultAccountID: String? {
        UserDefaults.standard.string(forKey: defaultAccountKey)
    }
}
