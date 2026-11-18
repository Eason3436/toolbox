import SwiftUI

extension Rating {
    var color: Color {
        switch self {
        case .again: Color.er.ratingAgain
        case .hard: Color.er.ratingHard
        case .good: Color.er.ratingGood
        case .easy: Color.er.ratingEasy
        }
    }
}

/// 複習頁底部的一塊玻璃，從頭到尾是同一塊在變形：
/// - 沒翻面：一條「顯示答案」
/// - 翻面：從這一條分出 4 個評分鍵（玻璃自己裂開）
/// - 評分：另外 3 個融回你按的那一顆，它帶著那個評分的顏色變回下一張的「顯示答案」，顏色一路退掉；
///   下一次翻面也從這一顆分開。卡片換下一張、上方時間軸多一顆同色的點，都用同一個 spring，中途再點會接著動
struct RatingBar: View {
    let isRevealed: Bool
    /// 每個評分下次出現的間隔（例如「10 分」「3 天」）；空的就不顯示
    var intervals: [Rating: String] = [:]
    /// 回頭看前面的卡：當時選的評分（其他按鈕變淡）
    var selected: Rating?
    /// 回頭看的卡已經又複習過一次，不能改評分
    var isLocked = false
    let onReveal: () -> Void
    let onRate: (Rating) -> Void

    /// 複習頁卡片、時間軸、這條按鈕共用的動畫
    static let morph = Animation.spring(duration: 0.4, bounce: 0.15)

    /// 上一次按的評分：沒翻面時就是這一顆撐滿整條
    @State private var anchor: Rating = .good
    @Namespace private var namespace

    private var shown: [Rating] { isRevealed ? Rating.allCases : [anchor] }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(shown) { rating in
                    key(rating)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
        }
    }

    private func key(_ rating: Rating) -> some View {
        let isDimmed = selected != nil && selected != rating
        let tint: Double = selected == rating ? 0.34 : (isDimmed ? 0.06 : 0.16)
        let glass: Glass = isRevealed ? .regular.tint(rating.color.opacity(tint)).interactive() : .regular.interactive()
        return Button {
            if isRevealed {
                withAnimation(Self.morph) {
                    anchor = rating
                    onRate(rating)
                }
            } else {
                onReveal()
            }
        } label: {
            ZStack {
                VStack(spacing: 2) {
                    Text(rating.title)
                        .font(.headline)
                    if let interval = intervals[rating] {
                        Text(interval)
                            .font(.erMonoSmall)
                            .opacity(0.8)
                    }
                }
                .foregroundStyle(rating.color)
                .opacity(isRevealed ? (isDimmed ? 0.4 : 1) : 0)
                .blur(radius: isRevealed ? 0 : 3)

                Text("顯示答案")
                    .font(.headline)
                    .foregroundStyle(Color.er.text)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(isRevealed ? 0 : 1)
                    .blur(radius: isRevealed ? 3 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRevealed && isDimmed && isLocked)
        .glassEffect(glass, in: .rect(cornerRadius: Theme.Radius.rating))
        .glassEffectID(rating.rawValue, in: namespace)
        .accessibilityLabel(isRevealed ? rating.title : "顯示答案")
        .accessibilityValue(isRevealed ? (intervals[rating] ?? "") : "")
        .accessibilityAddTraits(selected == rating ? .isSelected : [])
    }
}

#Preview("淺色") {
    @Previewable @State var revealed = false
    VStack {
        Spacer()
        RatingBar(
            isRevealed: revealed,
            intervals: [.again: "1 分", .hard: "6 分", .good: "1 天", .easy: "4 天"],
            onReveal: { withAnimation(RatingBar.morph) { revealed = true } },
            onRate: { _ in revealed = false }
        )
    }
    .padding(Theme.Spacing.page)
    .erPageBackground()
}

#Preview("深色") {
    VStack {
        Spacer()
        RatingBar(isRevealed: true, onReveal: {}, onRate: { _ in })
    }
    .padding(Theme.Spacing.page)
    .erPageBackground()
    .preferredColorScheme(.dark)
}
