import Foundation

struct NewsItem: Identifiable, Hashable, Sendable {
    var title: String
    var source: String
    var link: URL?
    var date: Date?
    var topic: String
    var id: String { title + (link?.absoluteString ?? "") }
}

struct MarketMove: Sendable {
    var name: String
    var change: Double
}

/// 免費新聞來源：Google 新聞 RSS（不需要 API 金鑰）
enum NewsService {
    static func search(_ query: String, topic: String, limit: Int = 5) async -> [NewsItem] {
        var comps = URLComponents(string: "https://news.google.com/rss/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query + " when:7d"),
            URLQueryItem(name: "hl", value: "zh-TW"),
            URLQueryItem(name: "gl", value: "TW"),
            URLQueryItem(name: "ceid", value: "TW:zh-Hant"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        let parser = RSSParser(topic: topic)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return Array(parser.items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
    }

    /// 搜尋關鍵字：台股用「代號 名稱」，美股用代號
    static func query(ticker: String, name: String) -> String {
        let t = ticker.uppercased()
        let code = t.replacingOccurrences(of: ".TWO", with: "").replacingOccurrences(of: ".TW", with: "")
        let hasCJK = name.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if t.hasSuffix(".TW") || t.hasSuffix(".TWO") {
            return hasCJK ? "\(code) \(name)" : "\(code) 股價"
        }
        if t.contains("-USD") { return "\(t.replacingOccurrences(of: "-USD", with: "")) 加密貨幣" }
        return hasCJK ? name : "\(t) 股票"
    }

    /// 大盤：台股加權、S&P 500、那斯達克
    static func marketMoves() async -> [MarketMove] {
        let indices = [("^TWII", "台股加權指數"), ("^GSPC", "S&P 500"), ("^IXIC", "那斯達克")]
        var out: [MarketMove] = []
        for (sym, name) in indices {
            if let q = try? await QuoteService.fetch(sym), q.previousClose > 0 {
                out.append(MarketMove(name: name, change: (q.price - q.previousClose) / q.previousClose))
            }
        }
        return out
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    let topic: String
    var items: [NewsItem] = []
    private var inItem = false
    private var current = ""
    private var title = "", link = "", pubDate = "", source = ""

    init(topic: String) { self.topic = topic }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" { inItem = true; title = ""; link = ""; pubDate = ""; source = "" }
        current = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        current += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inItem else { return }
        switch name {
        case "title": title = text
        case "link": link = text
        case "pubDate": pubDate = text
        case "source": source = text
        case "item":
            inItem = false
            // Google 新聞標題後面會帶「 - 來源」
            var t = title
            if !source.isEmpty, t.hasSuffix(" - \(source)") { t = String(t.dropLast(source.count + 3)) }
            if !t.isEmpty {
                items.append(NewsItem(title: t, source: source, link: URL(string: link),
                                      date: Self.dateFormatter.date(from: pubDate), topic: topic))
            }
        default: break
        }
        current = ""
    }
}
