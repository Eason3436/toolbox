import SwiftUI

// MARK: - 輸入邏輯（獨立、可測試）

/// 金額輸入規則：
/// - 最多 9 位整數、2 位小數，只允許一個小數點
/// - 開頭不可出現多餘的 0（「0」後輸入「5」變成「5」）
/// - 空字串代表 0
/// - 無效輸入回傳 false，且不改變內容
struct AmountInputLogic: Equatable {
    enum Key: Hashable {
        case digit(Int)
        case decimal
        case delete
    }

    private(set) var text: String
    var maxIntegerDigits: Int
    var maxFractionDigits: Int

    init(text: String = "", maxIntegerDigits: Int = 9, maxFractionDigits: Int = 2) {
        self.maxIntegerDigits = maxIntegerDigits
        self.maxFractionDigits = maxFractionDigits
        self.text = ""
        // 從外部帶入的字串（例如 "1,280"）逐字輸入，確保符合規則
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        for ch in cleaned {
            if let d = ch.wholeNumberValue { _ = press(.digit(d)) } else if ch == "." { _ = press(.decimal) }
        }
    }

    var hasDecimal: Bool { text.contains(".") }

    var integerPart: String {
        String(text.split(separator: ".", omittingEmptySubsequences: false).first ?? "")
    }

    var fractionPart: String {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    /// 轉成數值；"12." 視為 12，空字串視為 0
    var value: Double {
        let t = text.hasSuffix(".") ? String(text.dropLast()) : text
        return Double(t) ?? 0
    }

    @discardableResult
    mutating func press(_ key: Key) -> Bool {
        switch key {
        case .digit(let d):
            guard (0...9).contains(d) else { return false }
            if hasDecimal {
                guard fractionPart.count < maxFractionDigits else { return false }
                text.append(String(d))
                return true
            }
            if text == "0" {
                // 多餘的 0 不接受；其他數字取代開頭的 0
                guard d != 0 else { return false }
                text = String(d)
                return true
            }
            guard integerPart.count < maxIntegerDigits else { return false }
            text.append(String(d))
            return true
        case .decimal:
            guard !hasDecimal, maxFractionDigits > 0 else { return false }
            text = text.isEmpty ? "0." : text + "."
            return true
        case .delete:
            guard !text.isEmpty else { return false }
            text.removeLast()
            return true
        }
    }
}

// MARK: - 金額顯示（含正在輸入的小數點）

/// 依 Locale.current 顯示千分位與貨幣符號，正在打小數點（"12."）時保留小數點
struct AmountDisplay: View {
    var logic: AmountInputLogic
    var currencyCode: String? = Locale.current.currency?.identifier
    var font: Font = .system(size: 64, weight: .semibold, design: .rounded)
    var errorCount: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(formatted)
            .font(font)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: logic.value))
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.3), value: logic.text)
            .keyframeAnimator(initialValue: 0.0, trigger: errorCount) { content, x in
                content.offset(x: reduceMotion ? 0 : x)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0, duration: 0.0)
                    SpringKeyframe(-12, duration: 0.06)
                    SpringKeyframe(10, duration: 0.07)
                    SpringKeyframe(-7, duration: 0.06)
                    SpringKeyframe(4, duration: 0.05)
                    SpringKeyframe(0, duration: 0.06)
                }
            }
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// 例如 NT$1,280.5
    var formatted: String { Self.format(logic, currencyCode: currencyCode) }

    private var accessibilityText: String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: currencyCode ?? "TWD").precision(.fractionLength(0...2))
        return logic.value.formatted(style)
    }

    static func format(_ logic: AmountInputLogic, currencyCode: String?, locale: Locale = .current) -> String {
        let intValue = Decimal(string: logic.integerPart.isEmpty ? "0" : logic.integerPart) ?? 0
        var base: String
        if let code = currencyCode {
            base = intValue.formatted(.currency(code: code).precision(.fractionLength(0)).locale(locale))
        } else {
            base = intValue.formatted(.number.precision(.fractionLength(0)).locale(locale))
        }
        guard logic.hasDecimal else { return base }
        let sep = locale.decimalSeparator ?? "."
        let fraction = sep + logic.fractionPart
        // 貨幣符號在後面的語系（例如 1 280 €），把小數插在最後一個數字後面
        if let lastDigit = base.lastIndex(where: { $0.isNumber }) {
            let i = base.index(after: lastDigit)
            base.insert(contentsOf: fraction, at: i)
            return base
        }
        return base + fraction
    }
}

// MARK: - 自訂數字鍵盤

struct AmountKeypad: View {
    var onKey: (AmountInputLogic.Key) -> Void

    private let rows: [[AmountInputLogic.Key]] = [
        [.digit(1), .digit(2), .digit(3)],
        [.digit(4), .digit(5), .digit(6)],
        [.digit(7), .digit(8), .digit(9)],
        [.decimal, .digit(0), .delete],
    ]

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r], id: \.self) { key in
                        Button { onKey(key) } label: {
                            label(for: key)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .contentShape(.rect)
                        }
                        .buttonStyle(KeypadButtonStyle())
                        .accessibilityLabel(accessibilityName(key))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func label(for key: AmountInputLogic.Key) -> some View {
        switch key {
        case .digit(let d):
            Text("\(d)").font(.system(size: 30, weight: .medium, design: .rounded))
        case .decimal:
            Text(Locale.current.decimalSeparator ?? ".").font(.system(size: 30, weight: .medium, design: .rounded))
        case .delete:
            Image(systemName: "delete.left").font(.system(size: 24, weight: .medium))
        }
    }

    private func accessibilityName(_ key: AmountInputLogic.Key) -> String {
        switch key {
        case .digit(let d): "\(d)"
        case .decimal: "小數點"
        case .delete: "刪除"
        }
    }
}

struct KeypadButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.05), in: .rect(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - 完整的金額輸入元件（A：自訂鍵盤）

/// 像 Apple Cash 那樣輸入金額：每按一個數字，上方的大數字就滾動更新。
///
/// 這裡用的是 A 做法（自訂數字鍵盤）。
/// B 做法是放一個 opacity 0 的 TextField（keyboardType: .decimalPad）搭配 @FocusState 接收系統鍵盤，
/// 畫面上仍由 Text 負責顯示（TextField 本身不會有滾動動畫）。B 的優點是不用自己畫鍵盤、支援外接鍵盤，
/// 缺點是無法在每次按鍵前攔截並套用位數規則（只能事後修正字串，會閃一下），也做不到無效輸入時的抖動與錯誤回饋時機。
struct AnimatedAmountInput: View {
    @Binding var text: String
    var currencyCode: String? = Locale.current.currency?.identifier
    var showsKeypad: Bool = true

    @State private var errorCount = 0

    private var logic: AmountInputLogic { AmountInputLogic(text: text) }

    var body: some View {
        VStack(spacing: 20) {
            AmountDisplay(logic: logic, currencyCode: currencyCode, errorCount: errorCount)
                .frame(maxWidth: .infinity)
            if showsKeypad {
                AmountKeypad(onKey: press)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sensoryFeedback(.selection, trigger: text)
        .sensoryFeedback(.error, trigger: errorCount)
    }

    private func press(_ key: AmountInputLogic.Key) {
        var l = logic
        if l.press(key) {
            withAnimation(.snappy(duration: 0.3)) { text = l.text }
        } else {
            errorCount += 1
        }
    }
}

private struct AmountInputPreview: View {
    @State private var text = ""
    var body: some View {
        AnimatedAmountInput(text: $text)
            .padding()
    }
}

#Preview("AnimatedAmountInput") {
    AmountInputPreview()
}
