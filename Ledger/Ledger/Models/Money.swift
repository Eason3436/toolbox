import Foundation

enum Money {
    static let zeroDecimalCurrencies: Set<String> = ["TWD", "JPY", "KRW", "VND", "IDR", "CLP", "HUF"]

    static let commonCurrencies = ["TWD", "USD", "JPY", "EUR", "CNY", "HKD", "KRW", "GBP", "AUD", "SGD", "THB"]

    static func symbol(for currency: String) -> String {
        switch currency.uppercased() {
        case "TWD": "NT$"
        case "USD": "US$"
        case "JPY": "¥"
        case "CNY": "CN¥"
        case "EUR": "€"
        case "GBP": "£"
        case "KRW": "₩"
        case "HKD": "HK$"
        case "AUD": "A$"
        case "SGD": "S$"
        case "THB": "฿"
        default: currency.uppercased()
        }
    }

    /// 截圖風格：只顯示數字（千分位），不加幣別符號
    static func format(_ value: Double, currency: String = Prefs.mainCurrency, hidden: Bool = false, signed: Bool = false) -> String {
        if hidden { return "••••" }
        var value = value
        if abs(value) < 0.005 { value = 0 } // 避免出現 -0
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        let isZeroDecimal = zeroDecimalCurrencies.contains(currency.uppercased())
        let hasFraction = abs(value - value.rounded()) > 0.004
        f.minimumFractionDigits = (!isZeroDecimal && hasFraction) ? 2 : 0
        f.maximumFractionDigits = isZeroDecimal ? (hasFraction ? 2 : 0) : 2
        let s = f.string(from: NSNumber(value: value)) ?? "\(value)"
        if signed && value > 0 { return "+" + s }
        return s
    }

    static func percent(_ ratio: Double, digits: Int = 0) -> String {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = max(digits, 1)
        return f.string(from: NSNumber(value: ratio)) ?? "\(Int(ratio * 100))%"
    }

    /// 把使用者輸入（可能有逗號或全形數字）轉成數字
    static func parse(_ text: String) -> Double? {
        let halfWidth = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let cleaned = halfWidth.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }
}

enum DateText {
    static let cal = Calendar.current

    static func monthTitle(_ date: Date) -> String {
        let c = cal.dateComponents([.year, .month], from: date)
        return "\(c.month ?? 1)月 \(String(c.year ?? 2026))"
    }

    static func dueText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "EEE, M月d日"
        return f.string(from: date)
    }

    static func dayHeader(_ date: Date) -> String {
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: date)
    }

    static func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    static func short(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }

    static func monthInterval(_ date: Date) -> DateInterval {
        cal.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 86400 * 30)
    }

    static func addMonths(_ date: Date, _ n: Int) -> Date {
        cal.date(byAdding: .month, value: n, to: date) ?? date
    }
}
