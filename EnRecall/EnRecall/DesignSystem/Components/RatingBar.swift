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

/// 複習頁底部：沒翻面時 4 個玻璃按鈕併成一條「顯示答案」，翻面時分開成 4 個評分按鈕；評完再併回去
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

    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: isRevealed ? 10 : 0) {
                ForEach(Rating.allCases) { rating in
                    ratingButton(rating)
                }
            }
            .overlay {
                Button(action: onReveal) {
                    Text("顯示答案")
                        .font(.headline)
                        .foregroundStyle(Color.er.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isRevealed ? 0 : 1)
                .scaleEffect(isRevealed ? 0.9 : 1)
                .allowsHitTesting(!isRevealed)
                .accessibilityHidden(isRevealed)
            }
        }
    }

    private func ratingButton(_ rating: Rating) -> some View {
        let isDimmed = selected != nil && selected != rating
        let tint: Double = selected == rating ? 0.34 : (isDimmed ? 0.06 : 0.16)
        let glass: Glass = isRevealed ? .regular.tint(rating.color.opacity(tint)).interactive() : .regular.interactive()
        return Button {
            onRate(rating)
        } label: {
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
            .scaleEffect(isRevealed ? 1 : 0.8)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isRevealed || (isDimmed && isLocked))
        .glassEffect(glass, in: .rect(cornerRadius: Theme.Radius.rating))
        .glassEffectUnion(id: isRevealed ? nil : "merged", namespace: namespace)
        .accessibilityHidden(!isRevealed)
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
            onReveal: { withAnimation(.spring(duration: 0.35)) { revealed = true } },
            onRate: { _ in withAnimation(.spring(duration: 0.35)) { revealed = false } }
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
