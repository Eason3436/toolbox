import Foundation
import FoundationModels

/// 追問：先從逐字稿找出相關段落，再交給裝置上的模型回答（上下文小，不能整份塞進去）。
enum AskScope: Hashable {
    case day(String)
    case lecture(UUID)
    /// 最近 N 天的全部紀錄
    case recent(Int)

    var title: String {
        switch self {
        case .day(let key): "\(DayKey.date(from: key)?.formatted(.dateTime.month().day()) ?? key) 的紀錄"
        case .lecture: "這堂課"
        case .recent(let days): "最近 \(days) 天"
        }
    }
}

/// 可被引用的一小段原文。
struct Passage: Identifiable, Hashable, Sendable {
    var id = UUID()
    var time: Date
    var label: String
    var text: String
    /// 點進去看全文用
    var segmentRoute: SegmentRoute?
    var lectureID: UUID?
}

enum AskService {
    static var passageBudget: Int { AIConfig.usesGemini ? 150_000 : 1_700 }
    static var maxPassages: Int { AIConfig.usesGemini ? 400 : 8 }

    // MARK: 準備片段

    @MainActor
    static func passages(for scope: AskScope, store: RecapStore) -> [Passage] {
        var records: [DayRecord] = []
        var onlyLecture: UUID?
        var includeLectures = false
        switch scope {
        case .day(let key): records = [store.day(key)]
        case .lecture(let id):
            onlyLecture = id
            if let lecture = store.lecture(id) { records = [store.day(DayKey.key(for: lecture.start))] }
        case .recent(let days):
            // 最近幾天：連課堂一起查
            includeLectures = true
            records = store.dayKeys.prefix(days).map { store.day($0) }
        }
        var result: [Passage] = []
        for record in records {
            if onlyLecture == nil {
                for segment in record.segments where segment.hasText {
                    let route = SegmentRoute(dayKey: record.dayKey, id: segment.id)
                    let pieces = Summarizer.chunk(segment.bestTranscript ?? "", budget: 260)
                    for piece in pieces {
                        result.append(Passage(time: segment.start, label: label(segment.start, multiDay: records.count > 1), text: piece, segmentRoute: route))
                    }
                }
            }
            for lecture in record.lectures where onlyLecture == lecture.id || includeLectures {
                // 每 8 句一組，附上翻譯，讓中文問題也找得到英文內容
                let lines = lecture.lines
                var index = 0
                while index < lines.count {
                    let group = lines[index..<min(index + 8, lines.count)]
                    let text = group.map { line in
                        line.source + ((line.translation ?? "").isEmpty ? "" : "（\(line.translation!)）")
                    }.joined(separator: " ")
                    let time = lecture.start.addingTimeInterval(group.first?.offset ?? 0)
                    result.append(Passage(time: time, label: "課堂 " + label(time, multiDay: records.count > 1), text: text, lectureID: lecture.id))
                    index += 8
                }
            }
        }
        return result
    }

    private static func label(_ date: Date, multiDay: Bool) -> String {
        multiDay ? date.formatted(.dateTime.month().day().hour().minute()) : date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: 找相關片段

    /// 關鍵詞＋中文雙字詞比對打分，取分數最高、塞得進預算的片段（再依時間排序）。
    static func rank(_ passages: [Passage], question: String, keywords: [String]) -> [Passage] {
        let terms = Set((keywords + [question]).flatMap(tokens))
        guard !terms.isEmpty else { return [] }
        let scored = passages.map { passage -> (Passage, Double) in
            let haystack = passage.text.lowercased()
            var score = 0.0
            for keyword in keywords where keyword.count >= 2 {
                if haystack.contains(keyword.lowercased()) { score += 3 }
            }
            let passageTokens = Set(tokens(passage.text))
            score += Double(terms.intersection(passageTokens).count)
            return (passage, score)
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }

        var picked: [Passage] = []
        var used = 0
        for (passage, _) in scored {
            let cost = Summarizer.estimateTokens(passage.text)
            if used + cost > passageBudget { continue }
            picked.append(passage)
            used += cost
            if picked.count >= maxPassages { break }
        }
        return picked.sorted { $0.time < $1.time }
    }

    /// 英文單字（小寫）＋中日韓字的雙字組合。
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        var previousCJK: Character?
        let stop: Set<String> = ["the", "and", "what", "is", "are", "was", "of", "to", "a", "in", "on", "for", "that", "this", "did", "do", "how", "什麼", "怎麼", "有沒", "沒有", "一下", "我們", "他們", "就是", "然後", "那個", "這個", "今天"]
        func flushWord() {
            if word.count >= 2, !stop.contains(word) { result.append(word) }
            word = ""
        }
        for ch in text.lowercased() {
            if ch.isCJK {
                flushWord()
                if let previousCJK {
                    let bigram = String([previousCJK, ch])
                    if !stop.contains(bigram) { result.append(bigram) }
                }
                previousCJK = ch
            } else if ch.isLetter || ch.isNumber {
                previousCJK = nil
                word.append(ch)
            } else {
                previousCJK = nil
                flushWord()
            }
        }
        flushWord()
        return result
    }

    // MARK: 回答

    struct Result: Sendable {
        var answer: String
        var sources: [Passage]
    }

    static func ask(_ question: String, passages all: [Passage], previous: (q: String, a: String)?) async throws -> Result {
        guard ModelReadiness.current == .available else {
            throw RecapError.modelUnavailable(ModelReadiness.current.message)
        }

        // Gemini 上下文夠大：全部塞得下就整份給它，不用先找片段
        let total = all.reduce(0) { $0 + Summarizer.estimateTokens($1.text) }
        let sendAll = AIConfig.usesGemini && total <= passageBudget

        // 1. 讓模型把問題變成中英關鍵詞
        var keywords: [String] = []
        if !sendAll { do {
            let text = try await Summarizer.respondText(
                instructions: "你負責把使用者的問題轉成搜尋關鍵詞。只輸出關鍵詞，用逗號分隔。",
                prompt: "問題：\(question)\n請列出 3～8 個關鍵詞，包含繁體中文與對應的英文（逐字稿可能是英文）。"
            )
            keywords = text.components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
                .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-•「」\"'"))) }
                .filter { $0.count >= 2 && $0.count <= 20 }
        } catch {
            appLog.info("關鍵詞產生失敗，改用原句比對")
        } }

        // 2. 找片段；完全沒命中時，拿最近的幾段
        var picked = sendAll ? all : rank(all, question: question, keywords: keywords)
        if picked.isEmpty {
            var used = 0
            for passage in all.reversed() {
                let cost = Summarizer.estimateTokens(passage.text)
                if used + cost > passageBudget { break }
                picked.insert(passage, at: 0)
                used += cost
            }
        }
        guard !picked.isEmpty else {
            return Result(answer: "這個範圍裡還沒有轉好的文字可以查。", sources: [])
        }

        // 3. 回答
        let context = picked.enumerated().map { "[\($0.offset + 1)] \($0.element.label)：\($0.element.text)" }.joined(separator: "\n")
        var prompt = ""
        if let previous {
            prompt += "（上一題：\(previous.q.prefix(60))；上一題的回答：\(previous.a.prefix(120))）\n"
        }
        prompt += "以下是從使用者錄音逐字稿中找到的相關片段（語音辨識，可能有錯字）：\n\(context)\n\n問題：\(question)"
        prompt += "\n\n先回答問題，最後一行寫「出處：」加上用到的片段編號（例如 出處：1,3）。"
        let output: String
        do {
            output = try await Summarizer.respondText(
                instructions: "你是使用者的記憶助理，根據他錄音轉成的逐字稿回答問題。這是使用者自己的私人紀錄。一律用台灣繁體中文，回答具體並提到是幾點講的。只能根據提供的片段，找不到就說找不到，不要編造。",
                prompt: prompt
            )
        } catch {
            if Summarizer.isGuardrail(error) {
                return Result(answer: "這題被 \(AIConfig.engineName) 的安全機制擋下，沒辦法回答。下面是找到的相關片段，可以點進去看原文。", sources: picked)
            }
            throw error
        }
        var answerLines: [String] = []
        var cited: [Passage] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("出處") {
                let numbers = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
                cited = numbers.compactMap { picked.indices.contains($0 - 1) ? picked[$0 - 1] : nil }
            } else {
                answerLines.append(line)
            }
        }
        let answer = answerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(answer: answer, sources: cited.isEmpty ? picked : cited)
    }
}

private extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }
}
