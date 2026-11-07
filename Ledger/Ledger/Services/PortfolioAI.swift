import Foundation
import FoundationModels

@Generable
struct PortfolioInsight {
    @Guide(description: "表現走勢：今天與近期的漲跌、損益狀況，並引用提供的新聞與大盤走勢說明可能原因，3 到 5 句")
    var performance: String
    @Guide(description: "資產配置：股票、ETF、現金等比例是否均衡，2 到 4 句")
    var allocation: String
    @Guide(description: "集中度風險：單一持股或單一產業占比是否過高，2 到 4 句")
    var concentration: String
    @Guide(description: "使用者接著可能想問的問題，3 個，每個不超過 25 字", .count(3))
    var questions: [String]
}

/// 用 Apple Intelligence（裝置上、免費）分析投資組合
@MainActor
final class PortfolioAI: ObservableObject {
    @Published var insight: PortfolioInsight.PartiallyGenerated?
    @Published var running = false
    @Published var error: String?
    @Published var answers: [(question: String, answer: String)] = []
    @Published var answering = false
    @Published var news: [NewsItem] = []
    @Published var markets: [MarketMove] = []
    @Published var fetchingNews = false

    private var session: LanguageModelSession?

    static let instructions = """
    你是理財 App 裡的投資組合分析助理，用繁體中文回答，語氣像 Google 財經的 AI 摘要：具體、客觀、精簡。
    只根據使用者提供的持股資料、大盤漲跌與「近期新聞標題」分析。引用新聞時要具體（例如「根據經濟日報報導…」），
    不要編造清單以外的新聞或數字；新聞與漲跌的關聯只能說「可能」。
    台股習慣紅漲綠跌。不要給出保證獲利或明確買賣指示，可以提出分散風險等一般性建議。
    """

    /// targets：要找新聞的持股（代號、名稱），useWeb 關掉時只用持股資料
    func analyze(context: String, targets: [(ticker: String, name: String)], useWeb: Bool) async {
        guard NoticeParser.aiAvailable else {
            error = "Apple Intelligence \(NoticeParser.aiStatusText)"
            return
        }
        running = true
        error = nil
        answers = []
        insight = nil

        var fullContext = context
        if useWeb {
            fetchingNews = true
            let picked = Array(targets.prefix(5))
            async let moves = NewsService.marketMoves()
            var collected: [NewsItem] = []
            await withTaskGroup(of: [NewsItem].self) { group in
                for t in picked {
                    group.addTask {
                        await NewsService.search(NewsService.query(ticker: t.ticker, name: t.name),
                                                 topic: t.name, limit: picked.count > 3 ? 3 : 5)
                    }
                }
                for await items in group { collected += items }
            }
            markets = await moves
            news = collected.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            fetchingNews = false
            fullContext += Self.webSection(news: news, markets: markets)
        } else {
            news = []
            markets = []
        }
        webContext = fullContext

        let s = LanguageModelSession(instructions: Self.instructions)
        session = s
        do {
            let stream = s.streamResponse(to: "以下是我的投資組合資料，請分析：\n\(fullContext)", generating: PortfolioInsight.self)
            for try await partial in stream {
                insight = partial.content
            }
        } catch {
            self.error = "分析失敗：\(error.localizedDescription)"
        }
        running = false
    }

    /// 給「提問」用：包含新聞的完整資料
    var webContext = ""

    static func webSection(news: [NewsItem], markets: [MarketMove]) -> String {
        var lines: [String] = []
        if !markets.isEmpty {
            lines.append("\n今日大盤：" + markets.map { "\($0.name) \($0.change >= 0 ? "+" : "")\(Money.percent($0.change, digits: 2))" }.joined(separator: "、"))
        }
        if !news.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "M/d"
            lines.append("近期新聞標題（Google 新聞，最近 7 天）：")
            for n in news.prefix(15) {
                let d = n.date.map { f.string(from: $0) } ?? ""
                lines.append("- [\(n.topic)] \(n.title)（\(n.source) \(d)）")
            }
        } else {
            lines.append("（這次沒有抓到相關新聞）")
        }
        return lines.joined(separator: "\n")
    }

    func ask(_ question: String, context: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard NoticeParser.aiAvailable else {
            error = "Apple Intelligence \(NoticeParser.aiStatusText)"
            return
        }
        answering = true
        answers.append((q, ""))
        let idx = answers.count - 1
        let s = session ?? LanguageModelSession(instructions: Self.instructions + "\n投資組合資料：\n" + (webContext.isEmpty ? context : webContext))
        session = s
        do {
            let stream = s.streamResponse(to: q)
            for try await partial in stream {
                answers[idx].answer = partial.content
            }
        } catch {
            answers[idx].answer = "回答失敗：\(error.localizedDescription)"
        }
        answering = false
    }
}
