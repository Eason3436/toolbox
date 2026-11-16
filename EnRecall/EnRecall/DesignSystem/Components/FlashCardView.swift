import SwiftUI
import SwiftData

/// 複習的記憶卡。點卡片翻面（由外層處理），喇叭按鈕唸單字。
/// 背面在例句的位置放分頁（例句、搭配、近義字…），點了直接在卡片裡切換
struct FlashCardView: View {
    let card: Card
    let detail: CardDetail?
    let isFlipped: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: DetailTab = .examples

    private var deckLabel: String { card.deck?.name ?? "" }
    private var tabs: [DetailTab] { DetailTab.available(for: detail) }

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
        .frame(maxWidth: .infinity, maxHeight: 600)
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
        VStack(alignment: .leading, spacing: 12) {
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

            Divider().overlay(Color.er.outline)

            if tabs.isEmpty {
                basicExample
            } else {
                DetailTabBar(tabs: tabs, selection: $tab)
                ScrollView {
                    DetailTabContent(tab: tab, detail: detail, card: card)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(tab)
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .softScrollEdges()
                .scrollEdgeEffectHidden(true, for: .all)
            }

            Spacer(minLength: 0)
            Text(deckLabel)
                .font(.erLabel)
                .tracking(1.1)
                .foregroundStyle(Color.er.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.highlighter, Highlighter(word: card.word, forms: detail?.word?.forms))
    }

    /// 從 Claude 寫的字：只有一句例句
    @ViewBuilder
    private var basicExample: some View {
        if let example = card.example, !example.isEmpty {
            HStack(spacing: 6) {
                DetailLabel("例句")
                if card.source == .claude {
                    Chip(text: "AI 例句", style: .info)
                }
            }
            ScrollView {
                ExampleLines(en: example, zh: card.exampleZh)
            }
            .scrollBounceBehavior(.basedOnSize)
            .softScrollEdges()
            .scrollEdgeEffectHidden(true, for: .all)
        }
    }
}

/// 圓形喇叭按鈕
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
                .background(Color.er.fill, in: Circle())
                .overlay(Circle().strokeBorder(Color.er.outline, lineWidth: 1))
                .contentShape(Circle())
        }
        // 內容層用實心圓：玻璃在翻卡的 3D 旋轉裡會先變黑一下
        .buttonStyle(.plain)
        .accessibilityLabel("發音")
    }
}

#Preview("淺色") {
    @Previewable @State var flipped = false
    let container = PreviewData.container
    let card = (try? container.mainContext.fetch(FetchDescriptor<Card>()))?.first { $0.word == "abstract" }
    if let card {
        FlashCardView(card: card, detail: CardDetail.load(for: card.id, in: container.mainContext), isFlipped: flipped)
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
        FlashCardView(card: card, detail: nil, isFlipped: true)
            .padding(Theme.Spacing.page)
            .erPageBackground()
            .modelContainer(container)
            .preferredColorScheme(.dark)
    }
}
