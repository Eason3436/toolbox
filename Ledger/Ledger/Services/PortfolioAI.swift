import Foundation
import FoundationModels

@Generable
struct PortfolioInsight {
    @Guide(description: "表現走勢：今天與近期的漲跌、損益狀況與可能原因，2 到 4 句")
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

    private var session: LanguageModelSession?

    static let instructions = """
    你是理財 App 裡的投資組合分析助理，用繁體中文回答，語氣像 Google 財經的 AI 摘要：具體、客觀、精簡。
    只根據使用者提供的持股資料分析，不要編造新聞或你不知道的即時事件；如果需要推測原因，要說「可能」。
    台股習慣紅漲綠跌。不要給出保證獲利或明確買賣指示，可以提出分散風險等一般性建議。
    """

    func analyze(context: String) async {
        guard NoticeParser.aiAvailable else {
            error = "Apple Intelligence \(NoticeParser.aiStatusText)"
            return
        }
        running = true
        error = nil
        answers = []
        let s = LanguageModelSession(instructions: Self.instructions)
        session = s
        do {
            let stream = s.streamResponse(to: "以下是我的投資組合資料，請分析：\n\(context)", generating: PortfolioInsight.self)
            for try await partial in stream {
                insight = partial.content
            }
        } catch {
            self.error = "分析失敗：\(error.localizedDescription)"
        }
        running = false
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
        let s = session ?? LanguageModelSession(instructions: Self.instructions + "\n投資組合資料：\n" + context)
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
