import Foundation

/// 用 NSDataDetector 校正日期、電話、網址，並與 AI 結果合併去重。
enum EntityExtractor {
    /// 從文字偵測（OCR 全文）。
    static func detect(in text: String, referenceDate: Date = .now) -> ScreenshotEntities {
        var result = ScreenshotEntities()
        guard !text.isEmpty else { return result }
        let types: NSTextCheckingResult.CheckingType = [.date, .phoneNumber, .link, .address]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return result }
        let nsText = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let original = nsText.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            switch match.resultType {
            case .date:
                result.dates.append(DetectedDate(text: original, date: match.date, duration: match.duration > 0 ? match.duration : nil))
            case .phoneNumber:
                result.phoneNumbers.append(match.phoneNumber ?? original)
            case .link:
                if let url = match.url {
                    // 信箱也會被當成連結，保留原文即可
                    result.urls.append(url.scheme == "mailto" ? original : url.absoluteString)
                }
            case .address:
                result.places.append(original)
            default:
                break
            }
        }
        return result
    }

    /// 把 AI 給的日期原文盡量解析成實際時間。
    static func resolve(dateText: String) -> DetectedDate {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(location: 0, length: (dateText as NSString).length)
            if let match = detector.firstMatch(in: dateText, options: [], range: range) {
                return DetectedDate(text: dateText, date: match.date, duration: match.duration > 0 ? match.duration : nil)
            }
        }
        return DetectedDate(text: dateText, date: nil, duration: nil)
    }

    /// 合併 AI 結果與偵測結果，去除重複（忽略大小寫、空白與常見符號）。
    static func merge(ai: ScreenshotEntities, detected: ScreenshotEntities) -> ScreenshotEntities {
        var merged = ScreenshotEntities()
        merged.dates = dedupeDates(ai.dates.map { $0.date == nil ? resolve(dateText: $0.text) : $0 } + detected.dates)
        merged.places = dedupe(ai.places + detected.places)
        merged.urls = dedupe((ai.urls + detected.urls).map(normalizeURL), key: urlKey)
        merged.phoneNumbers = dedupe(ai.phoneNumbers + detected.phoneNumbers, key: phoneKey)
        merged.prices = dedupe(ai.prices)
        return merged
    }

    static func normalizeKey(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !"-–—_.,，。:：()（）".contains($0) }
    }

    static func phoneKey(_ text: String) -> String {
        var digits = text.filter(\.isNumber)
        // +886 9xx 與 09xx 視為同一支電話
        if digits.hasPrefix("886") { digits = "0" + digits.dropFirst(3) }
        return digits
    }

    static func urlKey(_ text: String) -> String {
        var key = text.lowercased()
        for prefix in ["https://", "http://"] where key.hasPrefix(prefix) { key.removeFirst(prefix.count) }
        if key.hasPrefix("www.") { key.removeFirst(4) }
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// 沒有 scheme 的網址補上 https://
    static func normalizeURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") || trimmed.contains("@") { return trimmed }
        return "https://" + trimmed
    }

    static func dedupe(_ values: [String], key: (String) -> String = normalizeKey) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = key(trimmed)
            guard !trimmed.isEmpty, !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            result.append(trimmed)
        }
        return result
    }

    static func dedupeDates(_ values: [DetectedDate]) -> [DetectedDate] {
        var seenText = Set<String>()
        var seenDates = Set<Date>()
        var result: [DetectedDate] = []
        for value in values {
            let k = normalizeKey(value.text)
            guard !k.isEmpty, !seenText.contains(k) else { continue }
            if let date = value.date, seenDates.contains(date) { continue }
            seenText.insert(k)
            if let date = value.date { seenDates.insert(date) }
            result.append(value)
        }
        return result
    }
}
