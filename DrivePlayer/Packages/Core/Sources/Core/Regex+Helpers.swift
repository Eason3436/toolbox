import Foundation

/// NSRegularExpression 的小包裝（Linux 的 Foundation 也有）。
struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = true) {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        // 規則都是寫死的，寫錯就是程式錯
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    struct Match {
        let range: Range<String.Index>
        let groups: [String?]
        let groupRanges: [Range<String.Index>?]

        func group(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
    }

    func firstMatch(in s: String) -> Match? {
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: ns) else { return nil }
        return convert(m, in: s)
    }

    func matches(in s: String) -> [Match] {
        let ns = NSRange(s.startIndex..., in: s)
        return regex.matches(in: s, range: ns).compactMap { convert($0, in: s) }
    }

    func contains(_ s: String) -> Bool { firstMatch(in: s) != nil }

    func replacing(in s: String, with template: String) -> String {
        let ns = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: ns, withTemplate: template)
    }

    private func convert(_ m: NSTextCheckingResult, in s: String) -> Match? {
        guard let r = Range(m.range, in: s) else { return nil }
        var groups: [String?] = []
        var ranges: [Range<String.Index>?] = []
        for i in 0..<m.numberOfRanges {
            if let gr = Range(m.range(at: i), in: s) {
                groups.append(String(s[gr]))
                ranges.append(gr)
            } else {
                groups.append(nil)
                ranges.append(nil)
            }
        }
        return Match(range: r, groups: groups, groupRanges: ranges)
    }
}

extension String {
    /// 收合連續空白並去掉頭尾空白
    var collapsingWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// 中文數字（一～九十九、兩、〇）或阿拉伯數字 → Int
enum ChineseNumber {
    static func parse(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(s) { return n }
        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        var total = 0
        var current = 0
        var sawAny = false
        for ch in s {
            if let d = digits[ch] {
                current = d
                sawAny = true
            } else if ch == "十" {
                total += (current == 0 ? 1 : current) * 10
                current = 0
                sawAny = true
            } else if ch == "百" {
                total += (current == 0 ? 1 : current) * 100
                current = 0
                sawAny = true
            } else {
                return nil
            }
        }
        return sawAny ? total + current : nil
    }
}
