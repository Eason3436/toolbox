import SwiftUI
import Photos

/// 首頁：這一組的前三張像扇子一樣攤開，從底部浮上來。點一下開始整理。
struct FanView: View {
    let cards: [DeckCard]
    let namespace: Namespace.ID
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false

    /// 每一張在扇子裡的位置：中間在最前面，左邊高一點，右邊低一點
    private struct Slot {
        let x: CGFloat
        let y: CGFloat
        let angle: Double
    }

    private func slot(_ depth: Int, card: CGSize) -> Slot {
        switch depth {
        case 0: Slot(x: 0, y: card.height * 0.06, angle: 0)
        case 1: Slot(x: -card.width * 0.46, y: -card.height * 0.04, angle: -7)
        default: Slot(x: card.width * 0.46, y: card.height * 0.02, angle: 6)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.5, 240)
            let card = CGSize(width: width, height: width * 4 / 3)
            ZStack {
                ForEach(cards) { item in
                    let s = slot(item.depth, card: card)
                    fanCard(item, size: card)
                        .rotationEffect(.degrees(risen ? s.angle : 0))
                        .offset(x: risen ? s.x : 0, y: risen ? s.y : startY(in: geo.size))
                        .opacity(risen || !reduceMotion ? 1 : 0)
                        .zIndex(-Double(item.depth))
                        .animation(animation(for: item.depth), value: risen)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(.rect)
            .onTapGesture(perform: onOpen)
        }
        .onAppear { risen = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("這一組照片")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("點兩下開始整理")
        .accessibilityAction(.default, onOpen)
    }

    /// 從畫面底下浮上來；減少動態效果時原地淡入
    private func startY(in size: CGSize) -> CGFloat {
        reduceMotion ? 0 : size.height
    }

    /// 用不同長度的彈簧錯開，不用固定延遲
    private func animation(for depth: Int) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.2) }
        return .spring(duration: 0.55 + 0.12 * Double(depth), bounce: 0.28)
    }

    @ViewBuilder
    private func fanCard(_ item: DeckCard, size: CGSize) -> some View {
        let base = AssetImage(asset: item.asset, targetSize: CGSize(width: size.width * 3, height: size.height * 3))
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white, lineWidth: 5)
            }
            .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
        if item.depth == 0 {
            // 點進去時從這張放大
            base.matchedTransitionSource(id: FanView.transitionID, in: namespace)
        } else {
            base
        }
    }

    static let transitionID = "deck"
}
