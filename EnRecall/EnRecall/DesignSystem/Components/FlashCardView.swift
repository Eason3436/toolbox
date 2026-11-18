import SwiftUI
import SwiftData

/// 複習的記憶卡。點卡片翻面（由外層處理），喇叭按鈕唸單字。
/// 背面在例句的位置放分頁（例句、搭配、近義字…），點了直接在卡片裡切換
struct FlashCardView: View {
    let card: Card
    let detail: CardDetail?
    let isFlipped: Bool
    /// 容易搞混的字（≠ adapt、adult），背面單字下面
    var lookalikes: [Lookalike] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: DetailTab = .examples

    private var deckLabel: String { card.deck?.name ?? "" }
    private var tabs: [DetailTab] { DetailTab.available(for: detail) }
    private var isPattern: Bool { detail?.pattern != nil || card.deck?.category == .pattern }

    /// 這張卡沒有目前選的分頁（例如句型卡沒有「例句」以外的某頁）就顯示第一頁
    private var shownTab: Binding<DetailTab> {
        Binding {
            tabs.contains(tab) ? tab : (tabs.first ?? .examples)
        } set: {
            tab = $0
        }
    }

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
                    .font(.system(size: isPattern ? 28 : 40, weight: .bold))
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.er.text)
                if !metaLine.isEmpty {
                    Text(metaLine)
                        .font(.erMono)
                        .foregroundStyle(Color.er.textSecondary)
                        .multilineTextAlignment(.center)
                }
                if !isPattern {
                    SpeakButton(text: card.word, size: 52)
                        .padding(.top, 8)
                }
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
                    .font(.system(size: isPattern ? 20 : 26, weight: .bold))
                    .foregroundStyle(Color.er.text)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: isPattern)
                if let pos = card.pos, !pos.isEmpty {
                    Text(pos)
                        .font(.erMono)
                        .foregroundStyle(Color.er.textSecondary)
                }
                Spacer(minLength: 0)
                if !isPattern {
                    SpeakButton(text: card.word, size: 40)
                }
            }
            Text(card.zh)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.er.text)
                .fixedSize(horizontal: false, vertical: true)

            if !lookalikes.isEmpty {
                LookalikeRow(items: lookalikes)
            }

            Divider().overlay(Color.er.outline)

            if tabs.isEmpty {
                basicExample
            } else {
                DetailTabBar(tabs: tabs, selection: shownTab)
                ScrollView {
                    DetailTabContent(tab: shownTab.wrappedValue, detail: detail, card: card)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(shownTab.wrappedValue)
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
        .environment(\.highlighter, Highlighter.forCard(card, detail: detail))
    }

    /// 從 Claude 寫的字：只有一句例句
    @ViewBuilder
    private var basicExample: some View {
        if let example = card.example, !example.isEmpty {
            HStack(spacing: 6) {
                DetailLabel("例句")
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

/// 「≠ adapt 適應　≠ adult 成人」：跟原本的字不一樣的字母上色
struct LookalikeRow: View {
    let items: [Lookalike]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("≠")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.er.textTertiary)
                    Text(spelled(item))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.er.text)
                    if let zh = item.zh {
                        Text(zh)
                            .font(.caption)
                            .foregroundStyle(Color.er.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.er.fill, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("不是 \(item.word)，\(item.zh ?? "")")
            }
        }
    }

    private func spelled(_ item: Lookalike) -> AttributedString {
        var result = AttributedString()
        for (offset, character) in item.word.enumerated() {
            var letter = AttributedString(String(character))
            if item.differing.contains(offset) {
                letter.foregroundColor = Color.er.accent
            }
            result += letter
        }
        return result
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
        FlashCardView(card: card, detail: CardDetail.load(for: card.id, in: container.mainContext), isFlipped: flipped,
                      lookalikes: [
                          Lookalike(word: "extract", zh: "取出", differing: []),
                          Lookalike(word: "abstain", zh: "戒除", differing: []),
                      ])
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
        FlashCardView(card: card, detail: nil, isFlipped: true,
                      lookalikes: [Lookalike(word: "adapt", zh: "適應", differing: [2])])
            .padding(Theme.Spacing.page)
            .erPageBackground()
            .modelContainer(container)
            .preferredColorScheme(.dark)
    }
}
