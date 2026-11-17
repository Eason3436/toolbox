import Foundation

/// 「85 天前」
enum RelativeDay {
    static func text(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        switch days {
        case ..<1: return "今天"
        case 1: return "昨天"
        case 2..<365: return "\(days.formatted()) 天前"
        default:
            let years = calendar.dateComponents([.year], from: start, to: today).year ?? days / 365
            return "\(max(years, 1).formatted()) 年前"
        }
    }
}

/// 從地圖反查到的完整地址，整理成卡片上的短地名
enum PlaceFormatter {
    /// 「彰化縣彰化市南瑤里…」→「彰化縣南瑤里」；「臺北市大安區…」→「臺北市大安區」。
    /// 不是台灣格式就回傳 nil，由呼叫端改用系統的短地址。
    static func short(fromFull address: String) -> String? {
        var text = address.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? address
        for word in ["台灣", "臺灣", "Taiwan", " ", "\n", ","] {
            text = text.replacingOccurrences(of: word, with: "")
        }
        text = text.replacingOccurrences(of: #"^\d+"#, with: "", options: .regularExpression)

        guard let countyRange = text.range(of: #"[\p{Han}]{2}[縣市]"#, options: .regularExpression) else { return nil }
        let county = String(text[countyRange])
        var rest = String(text[countyRange.upperBound...])

        var district: String?
        if let r = rest.range(of: #"^[\p{Han}]{1,3}?[區鄉鎮市]"#, options: .regularExpression) {
            district = String(rest[r])
            rest = String(rest[r.upperBound...])
        }
        if let r = rest.range(of: #"^[\p{Han}]{1,3}?[里村]"#, options: .regularExpression) {
            return county + rest[r]
        }
        return county + (district ?? "")
    }

    /// 縣市＋鄉鎮區（詳情頁的「行政區」）
    static func district(fromFull address: String) -> String? {
        var text = address.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? address
        text = text.replacingOccurrences(of: " ", with: "")
        guard let countyRange = text.range(of: #"[\p{Han}]{2}[縣市]"#, options: .regularExpression) else { return nil }
        let county = String(text[countyRange])
        let rest = text[countyRange.upperBound...]
        if let r = rest.range(of: #"^[\p{Han}]{1,3}?[區鄉鎮市]"#, options: .regularExpression) {
            return county + rest[r]
        }
        return county
    }
}

/// 從 ImageIO 讀到的屬性整理出拍攝資訊
struct ExifSummary: Equatable {
    var make: String?
    var model: String?
    var lens: String?
    var aperture: Double?
    var exposure: Double?
    var iso: Int?
    var focalLength: Double?
    var focalLength35: Int?

    init(properties: [String: Any]) {
        let tiff = properties["{TIFF}"] as? [String: Any] ?? [:]
        let exif = properties["{Exif}"] as? [String: Any] ?? [:]
        make = (tiff["Make"] as? String)?.trimmingCharacters(in: .whitespaces)
        model = (tiff["Model"] as? String)?.trimmingCharacters(in: .whitespaces)
        lens = exif["LensModel"] as? String
        aperture = (exif["FNumber"] as? NSNumber)?.doubleValue
        exposure = (exif["ExposureTime"] as? NSNumber)?.doubleValue
        iso = (exif["ISOSpeedRatings"] as? [NSNumber])?.first?.intValue
        focalLength = (exif["FocalLength"] as? NSNumber)?.doubleValue
        focalLength35 = (exif["FocalLenIn35mmFilm"] as? NSNumber)?.intValue
    }

    /// 「Apple iPhone 17 Pro Max」，型號已經含廠牌就不重複
    var device: String? {
        switch (make, model) {
        case let (make?, model?):
            return model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
        case let (nil, model?): return model
        case let (make?, nil): return make
        default: return nil
        }
    }

    var apertureText: String? {
        aperture.map { "ƒ/\($0.formatted(.number.precision(.fractionLength(0...1))))" }
    }

    var exposureText: String? {
        guard let exposure, exposure > 0 else { return nil }
        if exposure < 1 {
            return "1/\(Int((1 / exposure).rounded()).formatted()) 秒"
        }
        return "\(exposure.formatted(.number.precision(.fractionLength(0...1)))) 秒"
    }

    var isoText: String? {
        iso.map { "ISO \($0.formatted())" }
    }

    struct Parameter: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// 有值的拍攝參數：光圈、快門、ISO、焦距
    var parameters: [Parameter] {
        let all: [(String, String?)] = [
            ("光圈", apertureText),
            ("快門", exposureText),
            ("ISO", isoText),
            ("焦距", focalText),
        ]
        return all.compactMap { label, value in
            value.map { Parameter(label: label, value: $0) }
        }
    }

    /// 優先顯示等效焦距
    var focalText: String? {
        if let focalLength35 { return "\(focalLength35.formatted()) mm" }
        return focalLength.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) mm" }
    }
}
