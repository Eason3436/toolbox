import Foundation

/// 主頁的功能卡片，可以排序、顯示或隱藏
enum HomeSection: String, CaseIterable, Identifiable {
    case insights, upcomingBills, transactions, balanceChart, categoryPie, merchants, transfer, accountCard, budgets, goals, loans

    var id: String { rawValue }

    var label: String {
        switch self {
        case .insights: "消費分析"
        case .upcomingBills: "即將到期"
        case .transactions: "本月交易"
        case .balanceChart: "餘額走勢"
        case .categoryPie: "分類比例"
        case .merchants: "常去商家"
        case .transfer: "轉帳"
        case .accountCard: "帳戶卡片"
        case .budgets: "預算"
        case .goals: "儲蓄目標"
        case .loans: "借貸"
        }
    }

    var symbol: String {
        switch self {
        case .insights: "chart.bar.fill"
        case .upcomingBills: "calendar.badge.exclamationmark"
        case .transactions: "list.bullet.rectangle"
        case .balanceChart: "chart.xyaxis.line"
        case .categoryPie: "chart.pie.fill"
        case .merchants: "storefront.fill"
        case .transfer: "arrow.left.arrow.right"
        case .accountCard: "creditcard.fill"
        case .budgets: "gauge.with.dots.needle.33percent"
        case .goals: "target"
        case .loans: "person.2.fill"
        }
    }
}

struct HomeItem: Identifiable, Equatable {
    var section: HomeSection
    var visible: Bool
    var id: String { section.rawValue }
}

/// 存成 "transactions:1,balanceChart:1,…" 放在 UserDefaults
enum HomeLayout {
    static let key = "homeLayout"
    static let txCountKey = "homeTxCount"
    static let startTabKey = "startTab"
    static let rollNumbersKey = "rollNumbers"

    static let defaultItems: [HomeItem] = HomeSection.allCases.map { HomeItem(section: $0, visible: true) }

    static func decode(_ raw: String) -> [HomeItem] {
        var items: [HomeItem] = []
        for part in raw.split(separator: ",") {
            let kv = part.split(separator: ":")
            guard let s = HomeSection(rawValue: String(kv.first ?? "")), !items.contains(where: { $0.section == s }) else { continue }
            items.append(HomeItem(section: s, visible: kv.count < 2 || kv[1] != "0"))
        }
        // 新增的卡片補在最後
        var front = 0
        for s in HomeSection.allCases where !items.contains(where: { $0.section == s }) {
            // 消費分析、即將到期這兩個新卡片放在最上面，其餘補在最後
            if s == .insights || s == .upcomingBills {
                items.insert(HomeItem(section: s, visible: true), at: front)
                front += 1
            } else {
                items.append(HomeItem(section: s, visible: true))
            }
        }
        return items
    }

    static func encode(_ items: [HomeItem]) -> String {
        items.map { "\($0.section.rawValue):\($0.visible ? 1 : 0)" }.joined(separator: ",")
    }
}
