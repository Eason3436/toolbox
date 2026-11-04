import Foundation
import FoundationModels

// MARK: - 模型輸出格式

@Generable
struct SegmentDigest {
    @Guide(description: "15 字以內的繁體中文標題，說明這段在講什麼")
    var title: String
    @Guide(description: "1～4 個繁體中文重點，每點一句，只寫內容裡真的有的")
    var points: [String]
    @Guide(description: "提到要做的事、約定、期限（繁體中文）；沒有就留空陣列")
    var todos: [String]
}

@Generable
struct RecapOutput {
    @Guide(description: "今天的標題，12 字以內，繁體中文")
    var title: String
    @Guide(description: "2～3 句繁體中文，總結今天發生了什麼")
    var overview: String
    @Guide(description: "3～6 個今天最重要的重點，每點一句，繁體中文")
    var highlights: [String]
    @Guide(description: "所有提到要做的事、約定、期限；沒有就留空陣列")
    var todos: [String]
}

@Generable
struct LectureOutput {
    @Guide(description: "這堂課的主題，15 字以內，繁體中文")
    var title: String
    @Guide(description: "2～3 句繁體中文，說明這堂課教了什麼")
    var overview: String
    @Guide(description: "4～8 個課堂重點，繁體中文，每點一句")
    var keyPoints: [String]
    @Guide(description: "重要的原文術語，每個寫成「原文術語：繁體中文解釋」")
    var terms: [String]
    @Guide(description: "作業、考試、報告、截止日期等提醒，繁體中文；沒有就留空陣列")
    var todos: [String]
}

// MARK: - 模型狀態

enum ModelReadiness: Equatable {
    case available
    case appleIntelligenceOff
    case notReady
    case unsupported
    case other(String)

    static var current: ModelReadiness {
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
        case .available: "Apple Intelligence 已就緒"
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
    static let inputTokenBudget = 2_000

    private static let baseInstructions = """
    你是貼心的個人助理，負責整理使用者一天中錄下來的對話與聲音轉成的文字。
    文字是語音辨識的結果，可能有錯字、沒有標點、或混雜旁人的聲音，請推敲原意。
    一律使用台灣繁體中文。只寫內容裡真的出現的資訊，不要編造。
    """

    private static func makeSession(_ instructions: String) -> LanguageModelSession {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        return LanguageModelSession(model: model, instructions: instructions)
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

    // MARK: 一段錄音

    /// 摘要一段逐字稿（太長會自動切塊再合併）。
    static func summarizeSegment(_ transcript: String, timeLabel: String) async throws -> SegmentDigest {
        let chunks = chunk(transcript)
        if chunks.count <= 1 {
            return try await digest(text: chunks.first ?? transcript, header: "以下是 \(timeLabel) 錄到的逐字稿：")
        }
        var partial: [SegmentDigest] = []
        for (index, text) in chunks.enumerated() {
            try Task.checkCancellation()
            partial.append(try await digest(text: text, header: "以下是 \(timeLabel) 逐字稿的第 \(index + 1) 部分："))
        }
        let merged = partial.map { "・\($0.title)：\($0.points.joined(separator: "；"))\($0.todos.isEmpty ? "" : "（待辦：\($0.todos.joined(separator: "、"))）")" }
            .joined(separator: "\n")
        return try await digest(text: merged, header: "以下是同一段時間（\(timeLabel)）幾個部分的摘要，請合併成一份：")
    }

    private static func digest(text: String, header: String, depth: Int = 0) async throws -> SegmentDigest {
        let session = makeSession(baseInstructions)
        let prompt = "\(header)\n\(text)\n\n請產生標題、重點與待辦。"
        do {
            return try await session.respond(to: prompt, generating: SegmentDigest.self).content
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error, depth < 3 {
                // 太長：對半切再合併
                let half = chunk(text, budget: max(200, estimateTokens(text) / 2))
                var parts: [SegmentDigest] = []
                for piece in half { parts.append(try await digest(text: piece, header: header, depth: depth + 1)) }
                return SegmentDigest(title: parts.first?.title ?? "", points: Array(parts.flatMap(\.points).prefix(4)), todos: parts.flatMap(\.todos))
            }
            throw error
        }
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
            let groups = chunk(lines.joined(separator: "\n"))
            var merged: [String] = []
            for group in groups {
                try Task.checkCancellation()
                let d = try await digest(text: group, header: "以下是 \(dayLabel) 某個時段裡各段錄音的摘要，請合併成這個時段的摘要：")
                let firstTime = group.prefix(5)
                merged.append("\(firstTime) 起｜\(d.title)：\(d.points.joined(separator: "；"))\(d.todos.isEmpty ? "" : "（待辦：\(d.todos.joined(separator: "、"))）")")
            }
            lines = merged
        }
        let session = makeSession(baseInstructions + "\n你要把一天裡各時段的摘要，整理成「今日 Recap」。")
        let prompt = "以下是 \(dayLabel) 依時間排列的各段摘要：\n\(lines.joined(separator: "\n"))\n\n請產生今天的標題、總結、最重要的重點與所有待辦。"
        return try await session.respond(to: prompt, generating: RecapOutput.self).content
    }

    private static func line(for entry: Entry) -> String {
        let time = entry.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        var text = "\(time)\(entry.isLecture ? "【課堂】" : "")\(entry.title)：\(entry.points.joined(separator: "；"))"
        if !entry.todos.isEmpty { text += "（待辦：\(entry.todos.joined(separator: "、"))）" }
        return text
    }

    // MARK: 課堂

    /// 課後重點：原文逐字稿可能是英文，輸出一律繁體中文。
    static func summarizeLecture(sourceText: String, languageName: String) async throws -> LectureOutput {
        let instructions = """
        你是認真的助教，負責把一堂課的逐字稿整理成給台灣學生看的課堂筆記。
        逐字稿是\(languageName)的語音辨識結果，可能有錯字。輸出一律使用台灣繁體中文，術語保留原文並附中文解釋。
        只寫逐字稿裡真的有的內容，不要編造。
        """
        let chunks = chunk(sourceText)
        if chunks.count <= 1 {
            let session = makeSession(instructions)
            let prompt = "以下是整堂課的逐字稿：\n\(chunks.first ?? sourceText)\n\n請產生課堂筆記。"
            return try await session.respond(to: prompt, generating: LectureOutput.self).content
        }
        var notes: [String] = []
        for (index, text) in chunks.enumerated() {
            try Task.checkCancellation()
            let session = makeSession(instructions)
            let prompt = "以下是課堂逐字稿的第 \(index + 1)/\(chunks.count) 部分：\n\(text)\n\n請產生這部分的標題、重點與提醒。"
            let d = try await session.respond(to: prompt, generating: SegmentDigest.self).content
            notes.append("第\(index + 1)部分｜\(d.title)：\(d.points.joined(separator: "；"))\(d.todos.isEmpty ? "" : "（提醒：\(d.todos.joined(separator: "、"))）")")
        }
        // 部分摘要還是太多就再合併一輪
        while estimateTokens(notes.joined(separator: "\n")) > inputTokenBudget, notes.count > 1 {
            var merged: [String] = []
            for group in chunk(notes.joined(separator: "\n")) {
                let d = try await digest(text: group, header: "以下是一堂課連續幾個部分的筆記，請合併：")
                merged.append("\(d.title)：\(d.points.joined(separator: "；"))\(d.todos.isEmpty ? "" : "（提醒：\(d.todos.joined(separator: "、"))）")")
            }
            if merged.count >= notes.count { break }
            notes = merged
        }
        let session = makeSession(instructions)
        let prompt = "以下是同一堂課依序各部分的筆記：\n\(notes.joined(separator: "\n"))\n\n請合併成整堂課的課堂筆記。"
        return try await session.respond(to: prompt, generating: LectureOutput.self).content
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
