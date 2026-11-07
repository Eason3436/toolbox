import SwiftUI

/// 數字顯示元件：用 Apple 原生的 `.contentTransition(.numericText(value:))` 做數字滾動。
///
/// - 數值變大時往上滾、變小時往下滾，由 `numericText(value:)` 自動判斷。
/// - 動畫一定要在 Animation context 內才會生效，所以元件內加了 `.animation(_, value:)`；
///   呼叫端也可以用 `withAnimation(.snappy) { value = newValue }` 包住數值改變。
/// - 倒數計時請傳 `countsDown: true`，會改用 `.numericText(countsDown: true)`。
/// - `rollsOnAppear` 為 true 時，每次畫面出現都會從 0 滾到目前的數值（切換分頁時的效果）。
struct AnimatedNumberText<F: FormatStyle>: View where F.FormatInput == Double, F.FormatOutput == String {
    var value: Double
    var format: F
    var font: Font = .body
    var countsDown: Bool = false
    var rollsOnAppear: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double?

    private var displayed: Double { rollsOnAppear ? (shown ?? 0) : value }

    var body: some View {
        Text(displayed, format: format)
            .font(font)
            .monospacedDigit()
            .contentTransition(transition)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.35), value: displayed)
            .accessibilityLabel(Text(value, format: format))
            .onAppear {
                guard rollsOnAppear else { return }
                withAnimation(.snappy(duration: 0.6)) { shown = value }
            }
            .onDisappear {
                if rollsOnAppear { shown = 0 }
            }
            .onChange(of: value) { _, newValue in
                guard rollsOnAppear else { return }
                withAnimation(.snappy(duration: 0.35)) { shown = newValue }
            }
    }

    private var transition: ContentTransition {
        if reduceMotion { return .opacity }
        return countsDown ? .numericText(countsDown: true) : .numericText(value: displayed)
    }
}

extension AnimatedNumberText where F == FloatingPointFormatStyle<Double> {
    /// 預設：千分位整數
    init(value: Double, font: Font = .body, countsDown: Bool = false, rollsOnAppear: Bool = false) {
        self.init(value: value, format: .number.precision(.fractionLength(0)).grouping(.automatic),
                  font: font, countsDown: countsDown, rollsOnAppear: rollsOnAppear)
    }
}

/// App 統一的金額格式（千分位、零小數幣別不顯示小數、可加正號）
struct MoneyFormatStyle: FormatStyle {
    var currency: String
    var signed: Bool = false

    func format(_ value: Double) -> String {
        Money.format(value, currency: currency, signed: signed)
    }
}

/// 金額顯示：隱藏時顯示 ••••，否則用數字滾動
struct MoneyText: View {
    var value: Double
    var currency: String = Prefs.mainCurrency
    var hidden: Bool = false
    var signed: Bool = false
    var font: Font = .body
    var rollsOnAppear: Bool = true

    /// 設定裡可以關掉「進頁面時數字從 0 滾上來」
    @AppStorage(HomeLayout.rollNumbersKey) private var rollPref = true

    var body: some View {
        if hidden {
            Text("••••").font(font).contentTransition(.opacity)
        } else {
            AnimatedNumberText(value: value, format: MoneyFormatStyle(currency: currency, signed: signed),
                               font: font, rollsOnAppear: rollsOnAppear && rollPref)
        }
    }
}

private struct AnimatedNumberPreview: View {
    @State private var value = 1280.0
    var body: some View {
        VStack(spacing: 24) {
            AnimatedNumberText(value: value, font: .system(size: 64, weight: .semibold, design: .rounded))
            AnimatedNumberText(value: value, format: .currency(code: Locale.current.currency?.identifier ?? "TWD"), font: .title)
            AnimatedNumberText(value: value / 10000, format: .percent.precision(.fractionLength(1)), font: .title2)
            HStack {
                Button("−137") { value -= 137 }
                Button("+137") { value += 137 }
                Button("隨機") { value = Double(Int.random(in: 0...99_999)) }
            }
            .buttonStyle(.glass)
        }
        .padding()
    }
}

#Preview("AnimatedNumberText") {
    AnimatedNumberPreview()
}
