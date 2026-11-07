import Foundation
import SwiftData

struct ValuePoint: Identifiable, Equatable {
    var date: Date
    var value: Double
    var id: Date { date }
}

/// 帳戶餘額與總資產的每日歷史（用交易紀錄回推、股票用 Yahoo 歷史價）
enum History {
    static let cal = Calendar.current

    static func days(_ range: PriceRange) -> Int {
        switch range {
        case .m1: 30
        case .m3: 91
        case .m6: 182
        case .y1: 365
        }
    }

    /// 由舊到新的每日「日終」時間點
    static func dayEnds(_ count: Int) -> [Date] {
        let today = cal.startOfDay(for: .now)
        return (0..<count).reversed().map { cal.date(byAdding: .day, value: -$0 + 1, to: today)! }
    }

    /// 每天日終的帳戶餘額（帳戶自己的幣別）
    static func accountBalances(_ acc: Account, dayEnds: [Date]) -> [Double] {
        var deltas = ((acc.entries ?? []) + (acc.incomingTransfers ?? []))
            .map { ($0.date, $0.signedAmount(for: acc)) }
            .filter { $0.1 != 0 }
        deltas.sort { $0.0 > $1.0 }
        var balance = acc.balance
        var i = 0
        var out = Array(repeating: 0.0, count: dayEnds.count)
        for k in dayEnds.indices.reversed() {
            // 扣掉這一天之後才發生的交易
            while i < deltas.count, deltas[i].0 >= dayEnds[k] {
                balance -= deltas[i].1
                i += 1
            }
            out[k] = balance
        }
        return out
    }

    static func accountHistory(_ acc: Account, range: PriceRange) -> [ValuePoint] {
        let ends = dayEnds(days(range))
        let values = accountBalances(acc, dayEnds: ends)
        return zip(ends, values).map { ValuePoint(date: $0.addingTimeInterval(-1), value: $1) }
    }

    /// 總資產（主幣別）：帳戶餘額 ＋ 有報價的資產（歷史價 × 當天持股）＋ 手動資產（目前價值）
    @MainActor
    static func netWorthHistory(range: PriceRange) async -> [ValuePoint] {
        let ends = dayEnds(days(range))
        let assets = (try? Store.context.fetch(FetchDescriptor<Asset>())) ?? []
        let accounts = Store.accounts()
        let tickers = Array(Set(assets.filter(\.usesQuote).map { $0.ticker.uppercased() }))

        var prices: [String: [(Date, Double)]] = [:]
        await withTaskGroup(of: (String, [(Date, Double)]).self) { group in
            for t in tickers {
                group.addTask {
                    let h = (try? await QuoteService.history(t, range: range.rawValue)) ?? []
                    return (t, h.sorted { $0.0 < $1.0 })
                }
            }
            for await (t, h) in group { prices[t] = h }
        }

        var totals = Array(repeating: 0.0, count: ends.count)
        for acc in accounts {
            let rate = QuoteService.rate(from: acc.currency)
            let b = accountBalances(acc, dayEnds: ends)
            for k in ends.indices { totals[k] += b[k] * rate }
        }
        for a in assets {
            let rate = QuoteService.rate(from: a.currency)
            guard a.usesQuote else {
                for k in ends.indices { totals[k] += a.nativeValue * rate }
                continue
            }
            let series = prices[a.ticker.uppercased()] ?? []
            let lots = a.sortedLots
            var p = 0
            var price = series.first?.1 ?? a.lastPrice
            for k in ends.indices {
                while p < series.count, series[p].0 < ends[k] {
                    price = series[p].1
                    p += 1
                }
                let todayPrice = k == ends.count - 1 && a.lastPrice > 0 ? a.lastPrice : price
                let qty = lots.isEmpty ? a.quantity : lots.filter { $0.date < ends[k] }.reduce(0) { $0 + $1.quantity }
                totals[k] += qty * todayPrice * rate
            }
        }
        return zip(ends, totals).map { ValuePoint(date: $0.addingTimeInterval(-1), value: $1) }
    }
}
