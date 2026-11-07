import SwiftUI

/// 數字滾動動效示範：上方是金額輸入（自訂鍵盤），下方是計數器。
/// 從「設定 → 數字動效示範」進入。
struct ContentView: View {
    @State private var amount = ""
    @State private var counter = 0.0

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("金額輸入").font(.headline).foregroundStyle(.secondary)
                    AnimatedAmountInput(text: $amount)
                    Text("目前數值：\(AmountInputLogic(text: amount).value, format: .number)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: AmountInputLogic(text: amount).value))
                        .animation(.snappy, value: amount)
                }
                .cardStyle()

                VStack(spacing: 18) {
                    Text("計數器").font(.headline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AnimatedNumberText(value: counter, font: .system(size: 56, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    HStack(spacing: 10) {
                        demoButton("−1") { counter -= 1 }
                        demoButton("+1") { counter += 1 }
                        demoButton("+137") { counter += 137 }
                        demoButton("隨機") { counter = Double(Int.random(in: 0...99_999)) }
                    }
                    .sensoryFeedback(.selection, trigger: counter)
                }
                .cardStyle()
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("數字動效示範")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func demoButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.35)) { action() }
        } label: {
            Text(title).font(.headline.monospacedDigit()).frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
    }
}

#Preview("數字動效示範") {
    NavigationStack { ContentView() }
}
