import Foundation
import SwiftData

/// 免費報價來源：Yahoo 財經（台股、美股、ETF、加密貨幣、匯率）
struct Quote: Sendable {
    var symbol: String
    var price: Double
    var previousClose: Double
    var currency: String
    var name: String?
}

enum QuoteService {
    enum QuoteError: LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let s): "找不到「\(s)」的報價"
            }
        }
    }

    static func fetch(_ symbol: String) async throws -> Quote {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { throw QuoteError.notFound(symbol) }
        guard let enc = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?range=1d&interval=1d")
        else { throw QuoteError.notFound(symbol) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let meta = results.first?["meta"] as? [String: Any],
              let price = (meta["regularMarketPrice"] as? NSNumber)?.doubleValue
        else { throw QuoteError.notFound(symbol) }
        let prev = (meta["chartPreviousClose"] as? NSNumber)?.doubleValue
            ?? (meta["previousClose"] as? NSNumber)?.doubleValue ?? price
        let currency = (meta["currency"] as? String) ?? "USD"
        let name = (meta["shortName"] as? String) ?? (meta["longName"] as? String)
        return Quote(symbol: s, price: price, previousClose: prev, currency: currency.uppercased(), name: name)
    }

    /// 台股只輸入數字時，自動試 .TW（上市）與 .TWO（上櫃）
    static func resolve(_ input: String) async throws -> Quote {
        let s = input.trimmingCharacters(in: .whitespaces).uppercased()
        let isTaiwanCode = !s.isEmpty && s.allSatisfy { $0.isNumber || $0.isLetter } && s.first!.isNumber && !s.contains(".")
        if isTaiwanCode {
            if let q = try? await fetch(s + ".TW") { return q }
            return try await fetch(s + ".TWO")
        }
        return try await fetch(s)
    }

    /// 價格走勢：range 例如 1mo、3mo、6mo、1y
    static func history(_ symbol: String, range: String) async throws -> [(Date, Double)] {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        let interval = range == "1y" ? "1d" : "1d"
        guard let enc = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?range=\(range)&interval=\(interval)")
        else { throw QuoteError.notFound(symbol) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let stamps = result["timestamp"] as? [NSNumber],
              let indicators = result["indicators"] as? [String: Any],
              let quote = (indicators["quote"] as? [[String: Any]])?.first,
              let closes = quote["close"] as? [Any]
        else { throw QuoteError.notFound(symbol) }
        var points: [(Date, Double)] = []
        for (i, t) in stamps.enumerated() where i < closes.count {
            if let v = (closes[i] as? NSNumber)?.doubleValue {
                points.append((Date(timeIntervalSince1970: t.doubleValue), v))
            }
        }
        return points
    }

    // MARK: 匯率

    private static let ratesKey = "fxRates"

    /// 1 單位 currency 等於多少主幣別
    static func rate(from currency: String, to main: String = Prefs.mainCurrency) -> Double {
        let c = currency.uppercased(), m = main.uppercased()
        if c == m { return 1 }
        let rates = UserDefaults.standard.dictionary(forKey: ratesKey) as? [String: Double] ?? [:]
        return rates["\(c)\(m)"] ?? 1
    }

    static func hasRate(from currency: String, to main: String = Prefs.mainCurrency) -> Bool {
        let c = currency.uppercased(), m = main.uppercased()
        if c == m { return true }
        let rates = UserDefaults.standard.dictionary(forKey: ratesKey) as? [String: Double] ?? [:]
        return rates["\(c)\(m)"] != nil
    }

    static func updateRates(for currencies: Set<String>) async {
        let main = Prefs.mainCurrency.uppercased()
        var rates = UserDefaults.standard.dictionary(forKey: ratesKey) as? [String: Double] ?? [:]
        for c in currencies.map({ $0.uppercased() }) where c != main {
            if let q = try? await fetch("\(c)\(main)=X") {
                rates["\(c)\(main)"] = q.price
            }
        }
        UserDefaults.standard.set(rates, forKey: ratesKey)
    }

    // MARK: 更新全部資產

    static let lastRefreshKey = "lastQuoteRefresh"

    @MainActor
    static func refreshAll(context: ModelContext) async -> (updated: Int, failed: [String]) {
        let assets = (try? context.fetch(FetchDescriptor<Asset>())) ?? []
        var updated = 0
        var failed: [String] = []
        await withTaskGroup(of: (UUID, Quote?).self) { group in
            for a in assets where a.usesQuote {
                let id = a.id, ticker = a.ticker
                group.addTask { (id, try? await QuoteService.fetch(ticker)) }
            }
            for await (id, quote) in group {
                guard let a = assets.first(where: { $0.id == id }) else { continue }
                if let q = quote {
                    a.lastPrice = q.price
                    a.previousClose = q.previousClose
                    a.currency = q.currency
                    a.priceUpdatedAt = .now
                    updated += 1
                } else {
                    failed.append(a.name)
                }
            }
        }
        var currencies = Set(assets.map(\.currency))
        for acc in Store.accounts() { currencies.insert(acc.currency) }
        await updateRates(for: currencies)
        try? context.save()
        UserDefaults.standard.set(Date.now, forKey: lastRefreshKey)
        return (updated, failed)
    }
}
