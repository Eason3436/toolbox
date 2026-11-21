import Foundation

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case movie
    case episode
}

/// 從檔名看得出來的畫質／音訊標籤。順序就是顯示順序。
public enum QualityTag: String, Codable, Sendable, CaseIterable, Comparable {
    case uhd4K = "4K"
    case fullHD = "1080p"
    case hd = "720p"
    case dolbyVision = "DV"
    case hdr10Plus = "HDR10+"
    case hdr10 = "HDR10"
    case hdr = "HDR"
    case atmos = "Atmos"
    case hevc = "HEVC"

    public static func < (lhs: QualityTag, rhs: QualityTag) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct ParsedMedia: Hashable, Sendable, Codable {
    public var kind: MediaKind
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    /// 一個檔案兩集（S01E01E02、S01E01-E02）時的最後一集
    public var episodeEnd: Int?
    public var tags: [QualityTag]

    public init(
        kind: MediaKind, title: String, year: Int? = nil,
        season: Int? = nil, episode: Int? = nil, episodeEnd: Int? = nil,
        tags: [QualityTag] = []
    ) {
        self.kind = kind
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
        self.episodeEnd = episodeEnd
        self.tags = tags
    }
}

/// 檔名 → 片名／年份／季／集／畫質標籤。
///
/// 順序：去掉副檔名 → 抓標籤 → 處理 [...]、(...) → 抓集數（SxxExx、3x05、第x集、EP07、 - 12 ）
/// → 抓年份（1900–2099）→ 剩下的清理成片名。檔名裡沒有劇名時往上層資料夾找（略過 Season 1／第一季）。
public enum FilenameParser {
    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "ts", "m2ts", "webm", "wmv", "flv",
    ]

    /// - Parameters:
    ///   - filename: 檔名（可含副檔名）
    ///   - parentFolders: 上層資料夾名稱，**由近到遠**（直接上層在第一個）
    public static func parse(_ filename: String, parentFolders: [String] = []) -> ParsedMedia {
        let base = normalizeWidth(stripExtension(filename))
        let tags = detectTags(in: base)

        // 1. [..] 與 (..)：先記下裡面的集數／年份，再從主字串拿掉
        var brackets: [String] = []
        var main = base
        for m in P.bracket.matches(in: base) {
            if let inner = m.group(1) ?? m.group(2) { brackets.append(inner.trimmingCharacters(in: .whitespaces)) }
        }
        main = P.bracket.replacing(in: main, with: " ")

        var parens: [String] = []
        for m in P.paren.matches(in: main) {
            if let inner = m.group(1) { parens.append(inner.trimmingCharacters(in: .whitespaces)) }
        }
        main = P.paren.replacing(in: main, with: " ")

        // 2. 分隔符號：. 與 _ 當空白
        main = separators(main)

        var bracketEpisode: Int?
        var bracketYear: Int?
        var bracketTitles: [String] = []
        for b in brackets {
            let nb = separators(b)
            if let m = P.bareEpisode.firstMatch(in: nb), let n = m.group(1).flatMap(Int.init) {
                bracketEpisode = bracketEpisode ?? n
            } else if let y = yearValue(nb) {
                bracketYear = bracketYear ?? y
            } else if !isJunk(nb) {
                bracketTitles.append(nb)
            }
        }
        var parenYear: Int?
        var parenTitles: [String] = []
        for p in parens {
            let np = separators(p)
            if let y = yearValue(np) {
                parenYear = parenYear ?? y
            } else if !isJunk(np) {
                parenTitles.append(np)
            }
        }

        // 主字串空了（[組名][片名][13][1080p] 這種）：用括號裡的文字當片名，第一個是組名
        if !containsLetters(main) {
            let candidates = bracketTitles.count >= 2 ? Array(bracketTitles.dropFirst()) : bracketTitles
            if let t = candidates.first { main = t + " " + main }
            else if let t = parenTitles.first { main = t + " " + main }
        }

        // 3. 集數
        var result = ParsedMedia(kind: .movie, title: "", tags: tags)
        var titlePart = main
        if let ep = findEpisode(in: main) {
            result.kind = .episode
            result.season = ep.season
            result.episode = ep.episode
            result.episodeEnd = ep.episodeEnd
            titlePart = String(main[main.startIndex..<ep.titleEnd])
        } else if let n = bracketEpisode {
            result.kind = .episode
            result.episode = n
        }

        // 片名尾巴的季別：「Spy x Family S2」「药屋少女的呢喃 第二季」「Oshi no Ko 2nd Season」
        if result.kind == .episode, result.season == nil,
           let (season, rest) = trailingSeason(in: titlePart) {
            result.season = season
            titlePart = rest
        }

        // 4. 年份：取最後一個不在開頭的候選；片名只留年份前面的部分
        let junkCut = firstJunkIndex(in: titlePart)
        let searchable = String(titlePart[titlePart.startIndex..<junkCut])
        if let (year, yearRange) = findYear(in: searchable) {
            result.year = year
            titlePart = String(searchable[searchable.startIndex..<yearRange.lowerBound])
        } else {
            titlePart = searchable
        }
        result.year = result.year ?? parenYear ?? bracketYear

        result.title = cleanTitle(titlePart)

        // 只有數字的檔名（05.mp4）放在季資料夾裡 → 第 5 集
        let folderSeason = parentFolders.first.flatMap(seasonFromFolder)
        if result.kind == .movie, folderSeason != nil,
           let m = P.trailingNumber.firstMatch(in: result.title),
           let n = m.group(2).flatMap(Int.init) {
            result.kind = .episode
            result.episode = n
            result.title = cleanTitle(m.group(1) ?? "")
        }

        // 5. 資料夾線索
        if result.kind == .episode {
            if result.season == nil { result.season = folderSeason }
            if result.title.isEmpty, let show = showFromFolders(parentFolders) {
                result.title = show.title
                result.year = result.year ?? show.year
                if result.season == nil { result.season = show.season }
            }
            if result.season == nil { result.season = 1 }
        }
        return result
    }

    // MARK: - 資料夾

    /// 「Season 1」「S01」「第一季」「Specials」→ 季數（特別篇是 0）
    public static func seasonFromFolder(_ name: String) -> Int? {
        let n = separators(normalizeWidth(name)).collapsingWhitespace
        let stripped = P.paren.replacing(in: n, with: "").collapsingWhitespace
        if let m = P.folderSeason.firstMatch(in: stripped), let s = m.group(1).flatMap(Int.init) { return s }
        if let m = P.folderSeasonChinese.firstMatch(in: stripped), let s = m.group(1).flatMap(ChineseNumber.parse) { return s }
        if P.folderSpecials.contains(stripped) { return 0 }
        return nil
    }

    /// 由近到遠找第一個不是季資料夾的資料夾，當劇名
    static func showFromFolders(_ folders: [String]) -> (title: String, year: Int?, season: Int?)? {
        var season: Int?
        for f in folders {
            if let s = seasonFromFolder(f) {
                season = season ?? s
                continue
            }
            let parsed = parse(f)
            guard !parsed.title.isEmpty else { continue }
            return (parsed.title, parsed.year, season ?? parsed.season.flatMap { parsed.kind == .episode ? $0 : nil })
        }
        return nil
    }

    // MARK: - 步驟

    static func stripExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        let ext = name[name.index(after: dot)...].lowercased()
        return videoExtensions.contains(ext) ? String(name[..<dot]) : name
    }

    /// 全形括號、全形空白 → 半形
    static func normalizeWidth(_ s: String) -> String {
        s.replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "\u{3000}", with: " ")
    }

    static func separators(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    static func detectTags(in s: String) -> [QualityTag] {
        let n = separators(s)
        var tags: Set<QualityTag> = []
        if P.tag4K.contains(n) { tags.insert(.uhd4K) }
        if P.tag1080.contains(n) { tags.insert(.fullHD) }
        if P.tag720.contains(n) { tags.insert(.hd) }
        if P.tagDV.contains(n) { tags.insert(.dolbyVision) }
        if P.tagHDR10Plus.contains(n) { tags.insert(.hdr10Plus) }
        if P.tagHDR10.contains(n) { tags.insert(.hdr10) }
        if P.tagHDR.contains(n) { tags.insert(.hdr) }
        if P.tagAtmos.contains(n) { tags.insert(.atmos) }
        if P.tagHEVC.contains(n) { tags.insert(.hevc) }
        // 有 4K 就不另外標 1080p（檔名同時寫兩個通常是「4K 轉 1080p」以外的雜訊）
        if tags.contains(.uhd4K) { tags.remove(.fullHD); tags.remove(.hd) }
        return tags.sorted()
    }

    struct EpisodeMatch {
        var season: Int?
        var episode: Int
        var episodeEnd: Int?
        var titleEnd: String.Index
    }

    static func findEpisode(in s: String) -> EpisodeMatch? {
        // S01E02、S01E01E02、S01E01-E02、S01 E02
        if let m = P.sxxexx.firstMatch(in: s),
           let season = m.group(1).flatMap(Int.init), let ep = m.group(2).flatMap(Int.init) {
            return EpisodeMatch(season: season, episode: ep, episodeEnd: m.group(3).flatMap(Int.init), titleEnd: m.range.lowerBound)
        }
        // Season 1 Episode 5
        if let m = P.seasonEpisodeWords.firstMatch(in: s),
           let season = m.group(1).flatMap(Int.init), let ep = m.group(2).flatMap(Int.init) {
            return EpisodeMatch(season: season, episode: ep, titleEnd: m.range.lowerBound)
        }
        // 3x05
        if let m = P.nxnn.firstMatch(in: s),
           let season = m.group(1).flatMap(Int.init), let ep = m.group(2).flatMap(Int.init) {
            return EpisodeMatch(season: season, episode: ep, titleEnd: m.range.lowerBound)
        }
        // 第二季 第05集／第10話
        if let m = P.chineseEpisode.firstMatch(in: s), let ep = m.group(1).flatMap(ChineseNumber.parse) {
            var season: Int?
            var titleEnd = m.range.lowerBound
            if let sm = P.chineseSeason.firstMatch(in: s), sm.range.lowerBound < m.range.lowerBound,
               let n = sm.group(1).flatMap(ChineseNumber.parse) {
                season = n
                titleEnd = sm.range.lowerBound
            }
            return EpisodeMatch(season: season, episode: ep, titleEnd: titleEnd)
        }
        // EP07、E07
        if let m = P.epNumber.firstMatch(in: s), let ep = m.group(1).flatMap(Int.init) {
            return EpisodeMatch(season: nil, episode: ep, titleEnd: m.range.lowerBound)
        }
        // 「片名 - 12」（動畫字幕組）
        if let m = P.dashNumber.firstMatch(in: s), let ep = m.group(1).flatMap(Int.init), yearValue(m.group(1) ?? "") == nil {
            return EpisodeMatch(season: nil, episode: ep, titleEnd: m.range.lowerBound)
        }
        return nil
    }

    /// 片名尾巴的季別 → (季, 去掉季別後的片名)
    static func trailingSeason(in s: String) -> (Int, String)? {
        var head = s
        while let last = head.last, last.isWhitespace || last == "-" { head.removeLast() }
        for p in [P.trailingSeasonS, P.trailingSeasonOrdinal] {
            if let m = p.firstMatch(in: head), let n = m.group(1).flatMap(Int.init) {
                return (n, String(head[head.startIndex..<m.range.lowerBound]))
            }
        }
        if let m = P.trailingSeasonChinese.firstMatch(in: head), let n = m.group(1).flatMap(ChineseNumber.parse) {
            return (n, String(head[head.startIndex..<m.range.lowerBound]))
        }
        return nil
    }

    static func yearValue(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count == 4, let y = Int(t), (1900...2099).contains(y) else { return nil }
        return y
    }

    /// 最後一個不在開頭的年份（「1917 2019」→ 2019；「1917」→ 沒有年份）
    static func findYear(in s: String) -> (Int, Range<String.Index>)? {
        for m in P.year.matches(in: s).reversed() {
            guard let y = m.group(1).flatMap(Int.init) else { continue }
            let before = s[s.startIndex..<m.range.lowerBound]
            if containsLetters(String(before)) || before.contains(where: \.isNumber) {
                return (y, m.range)
            }
        }
        return nil
    }

    static func firstJunkIndex(in s: String) -> String.Index {
        // 開頭就是雜訊的話不切（避免片名整個不見）
        for m in P.junk.matches(in: s) where containsLetters(String(s[s.startIndex..<m.range.lowerBound])) {
            return m.range.lowerBound
        }
        return s.endIndex
    }

    static func isJunk(_ s: String) -> Bool {
        let rest = P.junk.replacing(in: s, with: " ")
        let cleaned = P.hexHash.replacing(in: rest, with: " ")
        return !containsLetters(cleaned) || P.groupLike.contains(s)
    }

    static func containsLetters(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    static func cleanTitle(_ s: String) -> String {
        var t = s.collapsingWhitespace
        let trimSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:：,，·+~"))
        t = t.trimmingCharacters(in: trimSet)
        return t.collapsingWhitespace
    }

    // MARK: - 規則

    private enum P {
        static let b = "(?<![A-Za-z0-9])"
        static let e = "(?![A-Za-z0-9])"

        static let bracket = Pattern(#"\[([^\]]*)\]|【([^】]*)】"#)
        static let paren = Pattern(#"\(([^)]*)\)"#)

        static let tag4K = Pattern("\(b)(2160p|4k|uhd)\(e)")
        static let tag1080 = Pattern("\(b)1080[pi]\(e)")
        static let tag720 = Pattern("\(b)720p\(e)")
        static let tagDV = Pattern("\(b)(dv|dovi|dolby ?vision)\(e)")
        static let tagHDR10Plus = Pattern("\(b)hdr10(\\+|plus)")
        static let tagHDR10 = Pattern("\(b)hdr10(?![A-Za-z0-9+])")
        static let tagHDR = Pattern("\(b)hdr\(e)")
        static let tagAtmos = Pattern("\(b)atmos\(e)")
        static let tagHEVC = Pattern("\(b)(hevc|[xh] ?265)\(e)")

        static let sxxexx = Pattern("\(b)s(\\d{1,2}) ?e(\\d{1,3})(?:(?: ?- ?|)e(\\d{1,3}))?(?![0-9])")
        static let seasonEpisodeWords = Pattern("\(b)season ?(\\d{1,2}) ?episode ?(\\d{1,3})(?![0-9])")
        static let nxnn = Pattern("\(b)(\\d{1,2})x(\\d{2,3})\(e)")
        static let chineseEpisode = Pattern(#"第\s*([0-9]{1,4}|[零〇一二兩两三四五六七八九十百]+)\s*[集話话回]"#)
        static let chineseSeason = Pattern(#"第\s*([0-9]{1,2}|[零〇一二兩两三四五六七八九十]+)\s*[季部]"#)
        static let epNumber = Pattern("\(b)(?:ep ?|e)(\\d{1,3})(?![0-9])")
        static let dashNumber = Pattern(#"\s[-–]\s+(\d{1,4})(?:v\d)?(?=\s|$)"#)
        static let bareEpisode = Pattern(#"^\s*(?:ep ?|e|第)?(\d{1,3})(?:v\d)?\s*[集話话]?\s*$"#)
        static let trailingNumber = Pattern(#"^(.*?)(?:^|\s|e|ep)(\d{1,3})$"#)

        static let trailingSeasonS = Pattern(#"\s(?:s|season ?)(\d{1,2})\s*$"#)
        static let trailingSeasonOrdinal = Pattern(#"\s(\d{1,2})(?:st|nd|rd|th) season\s*$"#)
        static let trailingSeasonChinese = Pattern(#"\s*第\s*([0-9]{1,2}|[一二兩两三四五六七八九十]+)\s*[季部]\s*$"#)

        static let folderSeason = Pattern(#"^(?:season|series|s)\s*(\d{1,2})(?:\s.*)?$"#)
        static let folderSeasonChinese = Pattern(#"^第\s*([0-9]{1,2}|[一二兩两三四五六七八九十]+)\s*季$"#)
        static let folderSpecials = Pattern(#"^(specials?|sp|特別篇|特别篇)$"#)

        static let year = Pattern("(?<![0-9])(19\\d{2}|20\\d{2})(?![0-9])")

        static let junk = Pattern(
            "\(b)(2160p|1080[pi]|720p|480p|4k|uhd|hdr10\\+?|hdr10plus|hdr|dv|dovi|dolby ?vision|web-?dl|webrip|bluray|blu-ray|bdrip|brrip|bdremux|remux|hdtv|dvdrip|x26[45]|h ?26[45]|hevc|avc|aac|e?ac3|ddp?[0-9]?|dts(?:-hd)?|truehd|atmos|flac|10bit|8bit|proper|repack|amzn|dsnp|atvp|hmax|nf|hulu|baha|cht|chs|big5|gb)(?![A-Za-z])"
        )
        static let hexHash = Pattern(#"(?<![A-Za-z0-9])[0-9A-F]{8}(?![A-Za-z0-9])"#)
        static let groupLike = Pattern(#"^(?:[0-9A-F]{8})$"#)
    }
}
