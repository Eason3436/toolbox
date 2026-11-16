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

/// 複習頁底部：「顯示答案」玻璃按鈕，翻面後變形成 4 個評分按鈕
struct RatingBar: View {
    let isRevealed: Bool
    /// 每個評分下次出現的間隔（例如「10 分」「3 天」）；空的就不顯示
    var intervals: [Rating: String] = [:]
    let onReveal: () -> Void
    let onRate: (Rating) -> Void

    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            if isRevealed {
                HStack(spacing: 8) {
                    ForEach(Rating.allCases) { rating in
                        ratingButton(rating)
                    }
                }
            } else {
                Button(action: onReveal) {
                    Text("顯示答案")
                        .font(.headline)
                        .foregroundStyle(Color.er.text)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.Radius.rating))
                .glassEffectID("reveal", in: namespace)
            }
        }
    }

    private func ratingButton(_ rating: Rating) -> some View {
        Button {
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
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(rating.color.opacity(0.16)).interactive(), in: .rect(cornerRadius: Theme.Radius.rating))
        .glassEffectID("rating-\(rating.rawValue)", in: namespace)
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
