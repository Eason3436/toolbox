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

    /// 依目前語系排列日期（例如台灣是「11月9日 星期日」，英文是「Sunday, Nov 9」）
    /// template 只列出要哪些欄位，順序與分隔符號交給系統決定；j 會依使用者設定選 12／24 小時制
    static func localized(_ date: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    static func monthTitle(_ date: Date) -> String { localized(date, "yMMMM") }

    static func dueText(_ date: Date) -> String { localized(date, "MMMdEEE") }

    static func dayHeader(_ date: Date) -> String {
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        return localized(date, "MMMdEEEE")
    }

    static func monthDay(_ date: Date) -> String { localized(date, "MMMd") }

    /// 只有月份（「11月」「Nov」）
    static func month(_ date: Date) -> String { localized(date, "MMM") }

    static func short(_ date: Date) -> String { localized(date, "Mdjmm") }

    static func time(_ date: Date) -> String { localized(date, "jmm") }

    static func monthInterval(_ date: Date) -> DateInterval {
        cal.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 86400 * 30)
    }

    static func addMonths(_ date: Date, _ n: Int) -> Date {
        cal.date(byAdding: .month, value: n, to: date) ?? date
    }
}
