import Foundation
import SwiftData

/// 資產頁的分組與換算
struct AssetLine: Identifiable {
    var id: String
    var name: String
    var detail: String
    var symbol: String
    var value: Double          // 主幣別
    var nativeValue: Double
    var currency: String
    var dayChange: Double?
    var asset: Asset?
    var account: Account?
}

struct AssetGroupSummary: Identifiable {
    var group: AssetGroup
    var lines: [AssetLine]
    var id: String { group.rawValue }
    var total: Double { lines.reduce(0) { $0 + $1.value } }
}

@MainActor
enum AssetMath {
    static func groups(assets: [Asset]? = nil, accounts: [Account]? = nil) -> [AssetGroupSummary] {
        let assets = assets ?? ((try? Store.context.fetch(FetchDescriptor<Asset>(sortBy: [SortDescriptor(\.order)]))) ?? [])
        let accounts = accounts ?? Store.accounts()
        var dict: [AssetGroup: [AssetLine]] = [:]

        for a in assets {
            let rate = QuoteService.rate(from: a.currency)
            var detail = a.kind.label
            if a.usesQuote {
                detail = "\(a.ticker.uppercased()) · \(Money.format(a.quantity, currency: "USD")) 單位"
            }
            let line = AssetLine(id: "asset-\(a.id)", name: a.name, detail: detail, symbol: a.kind.symbol,
                                 value: a.nativeValue * rate, nativeValue: a.nativeValue, currency: a.currency,
                                 dayChange: a.dayChangeRatio, asset: a)
            dict[a.kind.group, default: []].append(line)
        }
        for acc in accounts {
            let bal = acc.balance
            let rate = QuoteService.rate(from: acc.currency)
            let group: AssetGroup = (acc.kind == .credit && bal < 0) ? .liability : .cash
            let line = AssetLine(id: "account-\(acc.id)", name: acc.name, detail: acc.kind.label, symbol: acc.kind.symbol,
                                 value: bal * rate, nativeValue: bal, currency: acc.currency, account: acc)
            dict[group, default: []].append(line)
        }
        return AssetGroup.allCases.compactMap { g in
            guard let lines = dict[g], !lines.isEmpty else { return nil }
            return AssetGroupSummary(group: g, lines: lines)
        }
    }

    static func netWorth() -> Double {
        groups().reduce(0) { $0 + $1.total }
    }
}
