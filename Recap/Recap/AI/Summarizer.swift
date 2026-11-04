import Foundation
import FoundationModels

// MARK: - 輸出格式
// 注意：permissiveContentTransformations 只對「產生純文字」有效，guided generation（@Generable）
// 一律用預設安全機制，日常對話很容易被誤擋。所以這裡都請模型輸出固定格式的文字，再自己解析。

struct SegmentDigest: Sendable {
    var title: String
    var points: [String]
    var todos: [String]
}

struct RecapOutput: Sendable {
    var title: String
    var overview: String
    var highlights: [String]
    var todos: [String]
}

struct LectureOutput: Sendable {
    var title: String
    var overview: String
    var keyPoints: [String]
    var terms: [String]
    var todos: [String]
    var examPoints: [String] = []
    /// AI 判斷的科目（使用者沒選科目時）
    var subject: SchoolSubject?
}

// MARK: - 模型狀態

enum ModelReadiness: Equatable {
    case available
    case appleIntelligenceOff
    case notReady
    case unsupported
    case other(String)

    static var current: ModelReadiness {
        if AIConfig.usesGemini { return .available }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .notReady
        case .unavailable(.deviceNotEligible): return .unsupported
        case .unavailable(let reason): return .other(String(describing: reason))
        }
    }

    var message: String {
        switch self {
        case .available: AIConfig.usesGemini ? "使用 Gemini（\(AIConfig.model)）" : "Apple Intelligence 已就緒"
        case .appleIntelligenceOff: "Apple Intelligence 尚未開啟。請到「設定 → Apple Intelligence 與 Siri」開啟，摘要會先排著等。"
        case .notReady: "Apple Intelligence 模型還在下載或準備中，好了之後會自動整理。"
        case .unsupported: "這台裝置不支援 Apple Intelligence，只能轉文字、不能摘要。"
        case .other(let reason): "Apple Intelligence 目前無法使用（\(reason)）。"
        }
    }
}

// MARK: - 摘要

/// 用裝置上的 Foundation Models 摘要。上下文只有約 4096 tokens，所以一律切小塊、分層合併。
enum Summarizer {
    /// 每次送進模型的文字上限（估算 tokens）。留空間給指示和輸出。
    /// Gemini 的上下文很大，整份直接送；裝置上的模型要切小塊。
    static var inputTokenBudget: Int { AIConfig.usesGemini ? 200_000 : 2_000 }

    private static let baseInstructions = """
    你是貼心的個人助理，負責整理使用者錄下來的對話與聲音轉成的文字。
    文字是語音辨識的結果，可能有錯字、沒有標點、或混雜旁人的聲音，請推敲原意。
    這是使用者自己的私人筆記，內容可能包含日常閒聊、玩笑或新聞，照實中立地整理即可。
    摘要要「詳細但有高度」：先抓出主題與脈絡，再補上具體細節（人、事、時間、數字、結論），不要只寫空泛的一句話。
    一律使用台灣繁體中文。只寫內容裡真的出現的資訊，不要編造。
    """

    private static let digestFormat = """
    請嚴格照這個格式輸出，不要加其他說明：
    標題：（15 字以內，點出這段的主題）
    重點：
    - （3～6 點。依主題整理，每點寫成「主題：具體內容」，要包含誰、做了什麼、原因或結論、數字與時間等細節，一到兩句）
    待辦：
    - （提到要做的事、約定、期限；沒有就寫「無」）
    """

    static func makeSession(_ instructions: String) -> LanguageModelSession {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        return LanguageModelSession(model: model, instructions: instructions)
    }

    /// 產生純文字回應。選了 Gemini 就送到雲端；沒網路時若裝置模型可用就改用裝置模型。
    static func respondText(instructions: String, prompt: String) async throws -> String {
        if AIConfig.usesGemini {
            do {
                return try await GeminiClient.generate(system: instructions, prompt: prompt)
            } catch let error as URLError where SystemLanguageModel.default.isAvailable && estimateTokens(prompt) < 3_000 {
                appLog.info("Gemini 連不上（\(error.code.rawValue)），改用裝置上的模型")
            }
        }
        return try await makeSession(instructions).respond(to: prompt).content
    }

    /// 粗估 tokens：中日韓字約 1.2 token，其他字元約 0.3 token。
    static func estimateTokens(_ text: String) -> Int {
        var total: Double = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: total += 1.2
            default: total += 0.3
            }
        }
        return Int(total.rounded(.up))
    }

    /// 依 token 預算把文字切塊（盡量在換行或句號處切）。
    static func chunk(_ text: String, budget: Int = inputTokenBudget) -> [String] {
        let lines = text.split(whereSeparator: { $0 == "\n" }).map(String.init)
        var chunks: [String] = []
        var current = ""
        var currentTokens = 0
        func push() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
            currentTokens = 0
        }
        for line in lines {
            var pieces = [line]
            // 單行太長就硬切
            if estimateTokens(line) > budget {
                pieces = splitLong(line, budget: budget)
            }
            for piece in pieces {
                let t = estimateTokens(piece)
                if currentTokens + t > budget { push() }
                current += piece + "\n"
                currentTokens += t
            }
        }
        push()
        return chunks
    }

    private static func splitLong(_ line: String, budget: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in line {
            current.append(ch)
            if estimateTokens(current) >= budget, "。！？.!?，, ".contains(ch) || estimateTokens(current) >= budget + 50 {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: 解析

    /// 把「標題：… / 重點： - … - …」格式拆成段落。
    static func parseSections(_ text: String) -> [String: [String]] {
        let keys = ["科目", "標題", "總結", "概要", "重點", "課堂重點", "會考", "考試重點", "強調", "術語", "待辦", "提醒", "作業與提醒"]
        var result: [String: [String]] = [:]
        var current = "重點"
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: "**", with: "")
            guard !line.isEmpty else { continue }
            var matched = false
            for key in keys {
                for sep in ["：", ":"] where line.hasPrefix(key + sep) || line.hasPrefix("#" + key) || line.hasPrefix("## " + key) {
                    current = key
                    let rest = line.components(separatedBy: sep).dropFirst().joined(separator: sep).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { result[current, default: []].append(rest) }
                    matched = true
                    break
                }
                if matched { break }
            }
            if matched { continue }
            let item = stripBullet(line)
            if !item.isEmpty { result[current, default: []].append(item) }
        }
        // 「無」等於沒有
        for (key, items) in result {
            result[key] = items.filter { !["無", "无", "沒有", "none", "無。"].contains($0.lowercased()) && !$0.hasPrefix("（") }
        }
        return result
    }

    private static func stripBullet(_ line: String) -> String {
        var s = Substring(line)
        while let first = s.first, "-•・*·●▪︎◦ ".contains(first) { s = s.dropFirst() }
        // 「1.」「1、」「(1)」
        if let dot = s.firstIndex(where: { ".、)）".contains($0) }), s.distance(from: s.startIndex, to: dot) <= 3,
           s[s.startIndex..<dot].allSatisfy({ $0.isNumber || $0 == "(" || $0 == "（" }) {
            s = s[s.index(after: dot)...]
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func first(_ sections: [String: [String]], _ keys: [String]) -> String {
        for key in keys { if let v = sections[key]?.first, !v.isEmpty { return v } }
        return ""
    }

    private static func all(_ sections: [String: [String]], _ keys: [String]) -> [String] {
        keys.flatMap { sections[$0] ?? [] }
    }

    static func isGuardrail(_ error: Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError, case .guardrailViolation = error { return true }
        if let error = error as? GeminiError, case .blocked = error { return true }
        return false
    }

    static func isTooLong(_ error: Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = error { return true }
        return false
    }

    // MARK: 一段錄音

    /// 摘要一段逐字稿（太長會自動切塊再合併）。被安全機制擋下的小段會略過，不會讓整段失敗。
    static func summarizeSegment(_ transcript: String, timeLabel: String) async throws -> SegmentDigest {
        let chunks = chunk(transcript)
        if chunks.count <= 1 {
            return try await digest(text: chunks.first ?? transcript, header: "以下是 \(timeLabel) 錄到的逐字稿：")
        }
        var partial: [SegmentDigest] = []
        var lastError: Error?
        for (index, text) in chunks.enumerated() {
            try Task.checkCancellation()
            do {
                partial.append(try await digest(text: text, header: "以下是 \(timeLabel) 逐字稿的第 \(index + 1) 部分："))
            } catch {
                lastError = error
            }
        }
        guard !partial.isEmpty else { throw lastError ?? RecapError.modelUnavailable("無法摘要") }
        return try await merge(partial, header: "以下是同一段時間（\(timeLabel)）幾個部分的摘要，請合併成一份：")
    }

    /// 合併幾份摘要；合併被擋就直接拼起來。
    static func merge(_ parts: [SegmentDigest], header: String) async throws -> SegmentDigest {
        if parts.count == 1 { return parts[0] }
        let text = parts.map(line(for:)).joined(separator: "\n")
        do {
            return try await digest(text: text, header: header)
        } catch {
            if error is CancellationError { throw error }
            return SegmentDigest(title: parts[0].title, points: Array(parts.flatMap(\.points).prefix(8)), todos: parts.flatMap(\.todos))
        }
    }

    static func line(for d: SegmentDigest) -> String {
        "・\(d.title)：\(d.points.joined(separator: "；"))\(d.todos.isEmpty ? "" : "（待辦：\(d.todos.joined(separator: "、"))）")"
    }

    /// 一次摘要。太長或被擋時對半切再試（最多兩層）。
    static func digest(text: String, header: String, depth: Int = 0) async throws -> SegmentDigest {
        let prompt = "\(header)\n\(text)\n\n\(digestFormat)"
        do {
            let output = try await respondText(instructions: baseInstructions, prompt: prompt)
            let sections = parseSections(output)
            var title = first(sections, ["標題"])
            if title.isEmpty { title = String(text.prefix(14)) }
            return SegmentDigest(title: title, points: Array(all(sections, ["重點"]).prefix(AIConfig.usesGemini ? 12 : 8)), todos: all(sections, ["待辦", "提醒"]))
        } catch {
            guard (isTooLong(error) || isGuardrail(error)), depth < 2, estimateTokens(text) > 120 else { throw error }
            let halves = chunk(text, budget: max(100, estimateTokens(text) / 2 + 1))
            var parts: [SegmentDigest] = []
            for piece in halves {
                if let d = try? await digest(text: piece, header: header, depth: depth + 1) { parts.append(d) }
            }
            guard !parts.isEmpty else { throw error }
            return SegmentDigest(title: parts[0].title, points: Array(parts.flatMap(\.points).prefix(8)), todos: parts.flatMap(\.todos))
        }
    }

    // MARK: 校正逐字稿

    /// 用模型修正語音辨識的同音錯字、補標點。每塊不要太大，輸出才放得下。
    /// 中英夾雜：把中文模型與英文模型的結果合併成一份正確的逐字稿。
    static func mergeMixed(_ windows: [AlignedWindow], primaryName: String, secondaryName: String, vocabulary: [String], context: String) async -> String? {
        guard !windows.isEmpty else { return nil }
        let budget = AIConfig.usesGemini ? 30_000 : 650
        var groups: [[AlignedWindow]] = [[]]
        var used = 0
        for w in windows {
            let cost = estimateTokens(w.primary) + estimateTokens(w.secondary) + 10
            if used + cost > budget, !(groups.last?.isEmpty ?? true) { groups.append([]); used = 0 }
            groups[groups.count - 1].append(w)
            used += cost
        }
        let hint = vocabulary.isEmpty ? "" : "\n可能出現的專有名詞（照這個寫法）：\(vocabulary.prefix(80).joined(separator: "、"))"
        let instructions = """
        你是逐字稿校對員。\(context)說話的人會中英夾雜（例如中文句子裡穿插英文單字、術語或整句英文）。
        同一段錄音分別用\(primaryName)模型和\(secondaryName)模型辨識，依時間對齊給你。
        \(primaryName)模型遇到英文時常寫成發音相近的中文字（例如「麥特康德瑞亞」其實是 mitochondria），\(secondaryName)模型遇到中文時會寫出無意義的英文。
        請合併成一份正確的中英夾雜逐字稿：中文部分以中文結果為主，英文單字、術語、句子以英文結果為準並保留英文拼寫。
        修正錯字、補上標點，使用台灣繁體中文。不要摘要、不要刪減、不要加入新資訊。只輸出逐字稿全文。\(hint)
        """
        let brief = groups.count > 1 ? await contextBrief(windows.map(\.primary).joined(separator: "\n") + "\n" + windows.map(\.secondary).joined(separator: " "), context: context) : ""
        var output: [String] = []
        var changed = false
        for group in groups where !group.isEmpty {
            if Task.isCancelled { return nil }
            let original = group.map(\.primary).joined(separator: "\n")
            let prompt = group.map { "[\(Int($0.offset) / 60):\(String(format: "%02d", Int($0.offset) % 60))]\n\(primaryName)：\($0.primary)\n\(secondaryName)：\($0.secondary)" }.joined(separator: "\n\n")
            do {
                let merged = try await respondText(instructions: instructions, prompt: withContext(prompt, brief: brief, previous: output.last))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"\[\d+:\d{2}\]\s*"#, with: "", options: .regularExpression)
                let ratio = Double(merged.count) / Double(max(1, original.count))
                if !merged.isEmpty, ratio > 0.4, ratio < 2.5 {
                    output.append(merged)
                    changed = true
                } else {
                    output.append(original)
                }
            } catch {
                output.append(original)
            }
        }
        return changed ? output.joined(separator: "\n") : nil
    }

    /// 先通讀全文，抓出主題和專有名詞，之後每一小塊校正時都附上，讓模型知道整份在講什麼。
    static func contextBrief(_ text: String, context: String) async -> String {
        // 從頭、中、尾各取一段，裝置模型也看得完
        let sampleBudget = AIConfig.usesGemini ? 60_000 : 1_500
        var sample = text
        if estimateTokens(text) > sampleBudget {
            let parts = chunk(text, budget: sampleBudget / 3)
            let picks = [parts.first, parts.count > 2 ? parts[parts.count / 2] : nil, parts.last].compactMap { $0 }
            sample = picks.joined(separator: "\n…\n")
        }
        do {
            let brief = try await respondText(
                instructions: "你負責通讀語音辨識的逐字稿，抓出整份內容的脈絡。\(context)一律使用台灣繁體中文。",
                prompt: "\(sample)\n\n請用以下格式輸出，不要其他說明：\n主題：（一句話）\n專有名詞：（逐字稿裡出現或被辨識錯的人名、術語、英文單字的正確寫法，用頓號分隔，最多 30 個）"
            )
            return String(brief.prefix(600))
        } catch {
            return ""
        }
    }

    private static func withContext(_ text: String, brief: String, previous: String?) -> String {
        var prompt = ""
        if !brief.isEmpty { prompt += "【整份逐字稿的脈絡】\n\(brief)\n\n" }
        if let previous, !previous.isEmpty { prompt += "【前一段的結尾（只供參考，不要輸出）】\n…\(previous.suffix(120))\n\n" }
        return prompt.isEmpty ? text : prompt + "【要處理的這一段】\n" + text
    }

    static func correctTranscript(_ text: String, vocabulary: [String], context: String = "") async -> String? {
        let pieces = chunk(text, budget: AIConfig.usesGemini ? 30_000 : 600)
        guard !pieces.isEmpty else { return nil }
        let brief = pieces.count > 1 ? await contextBrief(text, context: context) : ""
        let hint = vocabulary.isEmpty ? "" : "\n可能出現的專有名詞（照這個寫法）：\(vocabulary.prefix(80).joined(separator: "、"))"
        let instructions = """
        你是逐字稿校對員。\(context)使用者給你的是語音辨識的結果，請：
        1. 修正同音、近音的錯字與明顯辨識錯誤（依上下文判斷）
        2. 補上適當的標點符號與分段
        3. 使用台灣繁體中文用字；英文、數字照原樣
        不要摘要、不要刪減、不要改寫語氣、不要加入新資訊。只輸出校對後的全文。\(hint)
        """
        var output: [String] = []
        var changed = false
        for piece in pieces {
            if Task.isCancelled { return nil }
            do {
                let fixed = try await respondText(instructions: instructions, prompt: withContext(piece, brief: brief, previous: output.last))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // 長度差太多就當作模型亂改，保留原文
                let ratio = Double(fixed.count) / Double(max(1, piece.count))
                if ratio > 0.7, ratio < 1.6 {
                    output.append(fixed)
                    changed = true
                } else {
                    output.append(piece)
                }
            } catch {
                output.append(piece)
            }
        }
        return changed ? output.joined(separator: "\n") : nil
    }

    // MARK: 今日 Recap

    struct Entry: Sendable {
        var time: Date
        var title: String
        var points: [String]
        var todos: [String]
        var isLecture: Bool
    }

    /// 把一天各段摘要合併成今日 Recap；太多段就分組、先合併成時段摘要再合併。
    static func dailyRecap(entries: [Entry], dayLabel: String) async throws -> RecapOutput {
        var lines = entries.sorted { $0.time < $1.time }.map(line(for:))
        var round = 0
        while estimateTokens(lines.joined(separator: "\n")) > inputTokenBudget, round < 4 {
            round += 1
            var merged: [String] = []
            for group in chunk(lines.joined(separator: "\n")) {
                try Task.checkCancellation()
                let start = String(group.prefix(5))
                if let d = try? await digest(text: group, header: "以下是 \(dayLabel) 某個時段裡各段錄音的摘要，請合併成這個時段的摘要：") {
                    merged.append("\(start) 起｜\(d.title)：\(d.points.joined(separator: "；"))\(d.todos.isEmpty ? "" : "（待辦：\(d.todos.joined(separator: "、"))）")")
                } else {
                    // 被擋就只留每行的標題部分
                    merged.append(contentsOf: group.components(separatedBy: "\n").map { String($0.prefix(40)) })
                }
            }
            if merged.count >= lines.count { break }
            lines = merged
        }
        let prompt = """
        以下是 \(dayLabel) 依時間排列的各段摘要：
        \(lines.joined(separator: "\n"))

        請整理成「今日 Recap」，嚴格照這個格式輸出：
        標題：（今天的標題，12 字以內）
        總結：（4～6 句的高層次總結：今天主要在忙什麼、有哪些重要的討論或決定、整體的脈絡）
        重點：
        - （6～10 點，依主題分組，每點寫成「主題：具體內容」，包含時間、人、決定、數字等細節）
        待辦：
        - （所有提到要做的事；沒有就寫「無」）
        """
        do {
            let output = try await respondText(instructions: baseInstructions, prompt: prompt)
            let s = parseSections(output)
            return RecapOutput(title: first(s, ["標題"]), overview: first(s, ["總結", "概要"]), highlights: all(s, ["重點"]), todos: all(s, ["待辦", "提醒"]))
        } catch {
            if error is CancellationError { throw error }
            // 最後一步被擋：直接用各段標題組一份
            let sorted = entries.sorted { $0.time < $1.time }
            return RecapOutput(
                title: "\(dayLabel)的紀錄",
                overview: "今天共整理了 \(entries.count) 段內容。",
                highlights: Array(sorted.map { "\($0.time.formatted(date: .omitted, time: .shortened)) \($0.title)" }.prefix(6)),
                todos: sorted.flatMap(\.todos)
            )
        }
    }

    private static func line(for entry: Entry) -> String {
        let time = entry.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        var text = "\(time)\(entry.isLecture ? "【課堂】" : "")\(entry.title)：\(entry.points.joined(separator: "；"))"
        if !entry.todos.isEmpty { text += "（待辦：\(entry.todos.joined(separator: "、"))）" }
        return text
    }

    // MARK: 課堂

    private static func lectureInstructions(_ languageName: String, subject: SchoolSubject?) -> String {
        let subjectLine: String
        if let subject, subject.isSeminar {
            return """
            你是認真的筆記助理，負責把一場講座或演講的逐字稿整理成重點筆記。
            \(subject.noteFocus)
            逐字稿是\(languageName)的語音辨識結果，講者可能中英夾雜，可能有錯字或把英文術語聽成中文諧音，請推敲原意並寫回正確用詞。
            特別標出講者說「最重要」「一定要記得」「我的結論是」的地方。
            這是使用者自己的私人筆記，照實中立地整理即可。
            輸出一律使用台灣繁體中文，英文術語保留原文並附中文解釋。只寫逐字稿裡真的有的內容，不要編造。
            """
        } else if let subject, subject != .general {
            let terms = subject.terms.prefix(40).joined(separator: "、")
            subjectLine = "這是台灣高中的「\(subject.title)」課（108 課綱）。\(subject.noteFocus)\n這科常見的名詞（辨識錯字時參考）：\(terms)"
        } else {
            subjectLine = "這是台灣高中的課。"
        }
        return """
        你是認真的高中助教，負責把一堂課的逐字稿整理成給台灣高中生複習用的課堂筆記。
        \(subjectLine)
        逐字稿是\(languageName)的語音辨識結果，老師常中英夾雜，可能有錯字或把英文術語聽成中文諧音，請依科目推敲原意並寫回正確術語。
        特別標出老師說「會考」「很重要」「要背」「學測常考」的地方，保留課本頁碼、題號、考試範圍與日期。
        這是學生自己的私人筆記，照實中立地整理即可。
        輸出一律使用台灣繁體中文，英文術語保留原文並附中文解釋。只寫逐字稿裡真的有的內容，不要編造。
        """
    }

    private static func lectureFormatText(_ subject: SchoolSubject?) -> String {
        guard subject?.isSeminar == true else { return lectureFormatClass }
        return lectureFormatClass
            .replacingOccurrences(of: "這堂課的主題", with: "這場講座的主題")
            .replacingOccurrences(of: "這堂課的主題、要解決的問題、核心觀念之間的關係、結論", with: "講者、主題、核心論點與結論")
            .replacingOccurrences(of: "會考：\n- （老師明確說會考、要背、常考、考試範圍的內容，寫出要考什麼；沒有就寫「無」）", with: "強調：\n- （講者特別強調、要聽眾記住的話或行動建議；沒有就寫「無」）")
            .replacingOccurrences(of: "老師強調會考的加上「★」", with: "講者強調的加上「★」")
            .replacingOccurrences(of: "（作業、小考、段考、報告、考試範圍與日期；沒有就寫「無」）", with: "（講者提到的資源、活動、要做的事與日期；沒有就寫「無」）")
    }

    private static let lectureFormatClass = """
    請嚴格照這個格式輸出，不要加其他說明：
    科目：（從 國文、英文、數學、物理、化學、生物、地球科學、歷史、地理、公民與社會、講座 選一個最符合的；都不像就寫「其他」）
    標題：（這堂課的主題，15 字以內）
    總結：（4～6 句的高層次總結：這堂課的主題、要解決的問題、核心觀念之間的關係、結論）
    重點：
    - （6～12 點，依課程段落或觀念分組，每點寫成「觀念：解釋與例子」，保留老師舉的例子、公式、數字；老師強調會考的加上「★」）
    會考：
    - （老師明確說會考、要背、常考、考試範圍的內容，寫出要考什麼；沒有就寫「無」）
    術語：
    - （原文術語：中文解釋；沒有就寫「無」）
    提醒：
    - （作業、小考、段考、報告、考試範圍與日期；沒有就寫「無」）
    """

    /// 課後重點：原文逐字稿可能是英文，輸出一律繁體中文。部分內容被擋時用其他部分繼續。
    static func summarizeLecture(sourceText: String, languageName: String, subject: SchoolSubject? = nil, memory: String = "") async throws -> LectureOutput {
        var instructions = lectureInstructions(languageName, subject: subject)
        if !memory.isEmpty { instructions += "\n" + memory }
        let lectureFormat = lectureFormatText(subject)
        let starHint = subject?.isSeminar == true ? "講者特別強調的地方在該點開頭加上「★」。" : "老師說會考、要背、很重要的地方在該點開頭加上「★會考」。"
        let chunks = chunk(sourceText)
        if chunks.count <= 1 {
            let text = chunks.first ?? sourceText
            do {
                return try await lectureNotes(instructions: instructions, prompt: "以下是整堂課的逐字稿：\n\(text)\n\n\(lectureFormat)")
            } catch {
                guard isGuardrail(error) || isTooLong(error) else { throw error }
                // 被擋：切小段各自整理再合併
            }
        }
        var parts: [SegmentDigest] = []
        var lastError: Error?
        let pieces = chunks.count <= 1 ? chunk(sourceText, budget: max(150, estimateTokens(sourceText) / 3 + 1)) : chunks
        for (index, text) in pieces.enumerated() {
            try Task.checkCancellation()
            do {
                parts.append(try await digest(text: text, header: "以下是課堂逐字稿（\(languageName)）的第 \(index + 1)/\(pieces.count) 部分，請用繁體中文整理。\(starHint)"))
            } catch {
                lastError = error
            }
        }
        guard !parts.isEmpty else { throw lastError ?? RecapError.modelUnavailable("無法整理") }
        var notes = parts.map(line(for:))
        while estimateTokens(notes.joined(separator: "\n")) > inputTokenBudget, notes.count > 1 {
            var merged: [String] = []
            for group in chunk(notes.joined(separator: "\n")) {
                if let d = try? await digest(text: group, header: "以下是一堂課連續幾個部分的筆記，請合併：") {
                    merged.append(line(for: d))
                }
            }
            if merged.isEmpty || merged.count >= notes.count { break }
            notes = merged
        }
        do {
            return try await lectureNotes(instructions: instructions, prompt: "以下是同一堂課依序各部分的筆記：\n\(notes.joined(separator: "\n"))\n\n請合併成整堂課的課堂筆記。\n\(lectureFormat)")
        } catch {
            if error is CancellationError { throw error }
            let points = parts.flatMap(\.points)
            return LectureOutput(
                title: parts[0].title,
                overview: "這堂課分成 \(parts.count) 個部分整理。",
                keyPoints: Array(points.prefix(10)),
                terms: [],
                todos: parts.flatMap(\.todos),
                examPoints: points.filter { $0.contains("★") }
            )
        }
    }

    private static func lectureNotes(instructions: String, prompt: String) async throws -> LectureOutput {
        let output = try await respondText(instructions: instructions, prompt: prompt)
        let s = parseSections(output)
        return LectureOutput(
            title: first(s, ["標題"]),
            overview: first(s, ["總結", "概要"]),
            keyPoints: all(s, ["重點", "課堂重點"]),
            terms: all(s, ["術語"]),
            todos: all(s, ["提醒", "待辦", "作業與提醒"]),
            examPoints: all(s, ["會考", "考試重點", "強調"]),
            subject: SchoolSubject.match(first(s, ["科目"]))
        )
    }

    /// 給失敗訊息用。
    static func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation: return "內容被安全機制擋下，無法摘要"
            case .exceededContextWindowSize: return "內容太長"
            case .unsupportedLanguageOrLocale: return "模型不支援這個語言"
            case .rateLimited: return "系統暫時限制使用（App 在背景時常見），稍後再試"
            case .assetsUnavailable: return "模型尚未就緒"
            default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
