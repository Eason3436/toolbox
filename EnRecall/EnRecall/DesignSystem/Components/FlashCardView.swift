import SwiftUI
import SwiftData

/// 複習的記憶卡。點卡片翻面（由外層處理），喇叭按鈕唸單字。
/// 背面有常用搭配；單字庫的字可以打開完整解釋（onMore）
struct FlashCardView: View {
    let card: Card
    let isFlipped: Bool
    var onMore: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collocations: [WordDetail.Collocation]
    @State private var hasDetail: Bool

    private static let collocationLimit = 5

    init(card: Card, isFlipped: Bool, onMore: (() -> Void)? = nil) {
        self.card = card
        self.isFlipped = isFlipped
        self.onMore = onMore
        let detail = card.detail
        _collocations = State(initialValue: Array((detail?.word?.allCollocations ?? []).prefix(Self.collocationLimit)))
        _hasDetail = State(initialValue: detail != nil)
    }

    private var deckLabel: String { card.deck?.name ?? "" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.flashCard, style: .continuous)
        ZStack {
            front
                .opacity(isFlipped ? 0 : 1)
                .accessibilityHidden(isFlipped)
            back
                .opacity(isFlipped ? 1 : 0)
                // 翻過去後背面要再轉 180 度，字才不會左右顛倒
                .rotation3DEffect(.degrees(reduceMotion ? 0 : 180), axis: (x: 0, y: 1, z: 0))
                .accessibilityHidden(!isFlipped)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: 560)
        .background(Color.er.surface, in: shape)
        .overlay(shape.strokeBorder(Color.er.outline, lineWidth: 1))
        .shadow(color: Color.er.shadow, radius: 2, y: 1)
        .rotation3DEffect(
            .degrees(reduceMotion ? 0 : (isFlipped ? 180 : 0)),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.4
        )
        .contentShape(shape)
    }

    private var metaLine: String {
        [card.phonetic, card.pos]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: 正面

    private var front: some View {
        VStack(spacing: 0) {
            Text(deckLabel)
                .font(.erLabel)
                .tracking(1.1)
                .foregroundStyle(Color.er.textTertiary)
            Spacer(minLength: 16)
            VStack(spacing: 12) {
                Text(card.word)
                    .font(.system(size: 40, weight: .bold))
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.er.text)
                if !metaLine.isEmpty {
                    Text(metaLine)
                        .font(.erMono)
                        .foregroundStyle(Color.er.textSecondary)
                        .multilineTextAlignment(.center)
                }
                SpeakButton(text: card.word, size: 52)
                    .padding(.top, 8)
            }
            Spacer(minLength: 16)
            Text("點卡片看答案")
                .font(.footnote)
                .foregroundStyle(Color.er.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 背面

    private var back: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                backContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            HStack(alignment: .center) {
                Text(deckLabel)
                    .font(.erLabel)
                    .tracking(1.1)
                    .foregroundStyle(Color.er.textTertiary)
                Spacer(minLength: 8)
                if hasDetail, let onMore {
                    Button("完整解釋", systemImage: "text.book.closed", action: onMore)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.glass)
                }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var backContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.word)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.er.text)
                    .minimumScaleFactor(0.6)
                if let pos = card.pos, !pos.isEmpty {
                    Text(pos)
                        .font(.erMono)
                        .foregroundStyle(Color.er.textSecondary)
                }
                Spacer(minLength: 0)
                SpeakButton(text: card.word, size: 40)
            }
            Text(card.zh)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.er.text)
                .fixedSize(horizontal: false, vertical: true)

            if let example = card.example, !example.isEmpty {
                Divider().overlay(Color.er.outline)
                HStack(spacing: 6) {
                    Text("例句")
                        .font(.erLabel)
                        .tracking(1.1)
                        .foregroundStyle(Color.er.textTertiary)
                    if card.source == .claude {
                        Chip(text: "AI 例句", style: .info)
                    }
                }
                Text(example)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.er.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let exampleZh = card.exampleZh, !exampleZh.isEmpty {
                    Text(exampleZh)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.er.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !collocations.isEmpty {
                Divider().overlay(Color.er.outline)
                Text("搭配")
                    .font(.erLabel)
                    .tracking(1.1)
                    .foregroundStyle(Color.er.textTertiary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(collocations.enumerated()), id: \.offset) { _, item in
                        CollocationLine(item: item)
                    }
                }
            }
        }
    }
}

/// 圓形玻璃喇叭按鈕
struct SpeakButton: View {
    let text: String
    var size: CGFloat = 44

    var body: some View {
        Button {
            SpeechService.shared.speak(text)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Color.er.text)
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("發音")
    }
}

#Preview("淺色") {
    @Previewable @State var flipped = false
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.word == "abstract" }
    if let card {
        FlashCardView(card: card, isFlipped: flipped, onMore: {})
            .padding(Theme.Spacing.page)
            .onTapGesture { withAnimation(.spring(duration: 0.35)) { flipped.toggle() } }
            .erPageBackground()
            .modelContainer(container)
    }
}

#Preview("深色") {
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.source == .claude }
    if let card {
        FlashCardView(card: card, isFlipped: true)
            .padding(Theme.Spacing.page)
            .erPageBackground()
            .modelContainer(container)
            .preferredColorScheme(.dark)
    }
}
