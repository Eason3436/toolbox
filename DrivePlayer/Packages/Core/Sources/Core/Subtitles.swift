import Foundation

/// 外掛字幕（SRT、WebVTT、ASS／SSA）。AVPlayer 不能直接載入外掛字幕，所以自己解析、自己畫。
public struct SubtitleCue: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct SubtitleTrack: Sendable {
    public let cues: [SubtitleCue]

    public init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
    }

    /// 某個時間點要顯示的字（同時有好幾句就換行接起來）
    public func text(at time: Double) -> String? {
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        // lo 是第一個開始時間大於 time 的；往前找還沒結束的
        var lines: [String] = []
        var i = lo - 1
        var looked = 0
        while i >= 0, looked < 30 {
            if cues[i].end > time { lines.append(cues[i].text) }
            i -= 1
            looked += 1
        }
        return lines.isEmpty ? nil : lines.reversed().joined(separator: "\n")
    }
}

public enum SubtitleParser {
    public static let extensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    public static func parse(_ text: String, fileExtension: String) -> SubtitleTrack {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch fileExtension.lowercased() {
        case "ass", "ssa": return SubtitleTrack(cues: parseASS(normalized))
        default: return SubtitleTrack(cues: parseSRT(normalized))
        }
    }

    /// SRT 與 WebVTT（時間行有「-->」的區塊）
    static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else { continue }
            let body = lines[(timeIndex + 1)...]
                .map(stripTags)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues
    }

    /// ASS／SSA 的 [Events] Dialogue
    static func parseASS(_ text: String) -> [SubtitleCue] {
        var fields = ["Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]
        var inEvents = false
        var cues: [SubtitleCue] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.hasPrefix("Format:") {
                fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard line.hasPrefix("Dialogue:") else { continue }
            let values = line.dropFirst(9).split(separator: ",", maxSplits: max(fields.count - 1, 0), omittingEmptySubsequences: false)
                .map { String($0) }
            guard values.count == fields.count,
                  let si = fields.firstIndex(of: "Start"), let ei = fields.firstIndex(of: "End"),
                  let ti = fields.firstIndex(of: "Text"),
                  let start = timestamp(values[si]), let end = timestamp(values[ei]) else { continue }
            var body = values[ti]
            body = body.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            body = body.replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues
    }

    /// 「00:01:02,500」「01:02.500」「0:01:02.50」→ 秒
    static func timestamp(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    private static func stripTags(_ line: String) -> String {
        line.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
    }

    /// 同資料夾的字幕檔裡，哪些跟影片同名（「電影.srt」「電影.zh-TW.srt」「電影.chs.ass」）
    public static func matches(subtitleName: String, videoName: String) -> Bool {
        func base(_ name: String) -> String {
            guard let dot = name.lastIndex(of: ".") else { return name.lowercased() }
            return String(name[..<dot]).lowercased()
        }
        let video = base(videoName)
        let sub = base(subtitleName)
        return sub == video || sub.hasPrefix(video + ".") || sub.hasPrefix(video + "_") || sub.hasPrefix(video + "-")
    }
}

/// 字幕與音軌的語言偏好
public enum MediaLanguage: String, CaseIterable, Sendable, Identifiable {
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .traditionalChinese: "繁體中文"
        case .simplifiedChinese: "簡體中文"
        case .english: "英文"
        case .japanese: "日文"
        case .korean: "韓文"
        }
    }

    /// 分數越高越符合；0 表示不符合
    public func score(languageTag: String?, name: String) -> Int {
        let tag = (languageTag ?? "").lowercased()
        let lower = name.lowercased()
        let primary = tag.split(separator: "-").first.map(String.init) ?? tag
        func nameHas(_ words: [String]) -> Bool { words.contains { lower.contains($0.lowercased()) } }
        let traditionalWords = ["繁", "正體", "traditional", "cht", "zh-tw", "zh_tw", "zh-hk", "zh-hant", ".tc", "big5", "tc."]
        let simplifiedWords = ["简", "簡", "simplified", "chs", "zh-cn", "zh_cn", "zh-hans", ".sc", "gb", "sc."]
        switch self {
        case .traditionalChinese, .simplifiedChinese:
            let isChinese = ["zh", "chi", "zho", "cmn", "yue"].contains(primary)
                || nameHas(["中文", "中字", "chinese", "繁", "简", "簡", "chs", "cht"])
            guard isChinese else { return 0 }
            let traditional = tag.contains("hant") || tag.hasSuffix("-tw") || tag.hasSuffix("-hk") || tag.hasSuffix("-mo") || nameHas(traditionalWords)
            let simplified = tag.contains("hans") || tag.hasSuffix("-cn") || tag.hasSuffix("-sg") || nameHas(simplifiedWords)
            let wantTraditional = self == .traditionalChinese
            if wantTraditional ? traditional : simplified { return 3 }
            if wantTraditional ? simplified : traditional { return 1 }
            return 2
        case .english:
            return primary == "en" || primary == "eng" || nameHas(["english", ".en.", "英"]) ? 3 : 0
        case .japanese:
            return primary == "ja" || primary == "jpn" || nameHas(["japanese", ".ja.", ".jp.", "日"]) ? 3 : 0
        case .korean:
            return primary == "ko" || primary == "kor" || nameHas(["korean", ".ko.", "韓", "韩"]) ? 3 : 0
        }
    }

    /// 從選項裡挑最符合的；都不符合回傳 nil
    public func bestIndex(_ options: [(languageTag: String?, name: String)]) -> Int? {
        var best: (index: Int, score: Int)?
        for (i, option) in options.enumerated() {
            let s = score(languageTag: option.languageTag, name: option.name)
            if s > 0, s > (best?.score ?? 0) { best = (i, s) }
        }
        return best?.index
    }
}
