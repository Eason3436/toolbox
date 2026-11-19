import SwiftUI
import Photos

/// 首頁：這一組的前三張像扇子一樣攤開，從底部浮上來。點一下開始整理。
///
/// 滑動換張的手感移植自 Bencho 的「Card swap」（MIT，bencho.dev/licence）：
/// 抓住最前面那張拖一下或甩出去，它直接退到最後面，其他張往前一格。
///
/// ── 一張卡就是它的位置 ──────────────────────────────
/// 順序是唯一的狀態（`PhotoDeckModel.sendToBack()` 只是把前面那張排到最後）。
/// 位置是固定的，換位置就是改它在順序裡的位置，讓動畫帶過去。
/// 被送到後面的那張「立刻」拿到最後面的繪製順序（zIndex 不做動畫），
/// 所以它是從其他卡的後面退過去的，不會蓋在新的前面那張上。
struct FanView: View {
    let cards: [DeckCard]
    let namespace: Namespace.ID
    let onOpen: () -> Void
    let onSendBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false
    /// 手指拖著前面那張的位移；只有那一張會動
    @State private var drag: CGSize = .zero
    @State private var swaps = 0

    /// 每一張在扇子裡的位置：中間在最前面，左邊高一點，右邊低一點
    private struct Slot {
        let x: CGFloat
        let y: CGFloat
        let angle: Double
        var scale: CGFloat = 1
        var opacity: Double = 1
    }

    private func slot(_ depth: Int, card: CGSize) -> Slot {
        switch depth {
        case 0: Slot(x: 0, y: card.height * 0.06, angle: 0)
        case 1: Slot(x: -card.width * 0.46, y: -card.height * 0.04, angle: -7)
        case 2: Slot(x: card.width * 0.46, y: card.height * 0.02, angle: 6)
        // 第四張以後：躲在中間那張正後方、縮小、看不見。
        // 剛送到後面的那張會退到這裡淡掉，下一張從這裡長出來
        default: Slot(x: 0, y: -card.height * 0.05, angle: 0, scale: 0.86, opacity: 0)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.5, 240)
            let card = CGSize(width: width, height: width * 4 / 3)
            ZStack {
                ForEach(cards) { item in
                    let s = slot(item.depth, card: card)
                    let front = item.depth == 0
                    let held = front ? rubber(drag) : .zero
                    fanCard(item, size: card)
                        .scaleEffect(s.scale)
                        // 拖動時跟著手斜一點：每 20pt 轉 1 度
                        .rotationEffect(.degrees(risen ? s.angle + held.width * 0.05 : 0))
                        .offset(x: (risen ? s.x : 0) + held.width,
                                y: (risen ? s.y : startY(in: geo.size)) + held.height)
                        .opacity(risen || !reduceMotion ? s.opacity : 0)
                        .zIndex(-Double(item.depth))
                        .animation(animation(for: item.depth), value: risen)
                        .transition(.opacity)
                        .allowsHitTesting(front)
                        .gesture(dragGesture, including: front ? .all : .subviews)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(.rect)
            .onTapGesture(perform: onOpen)
        }
        .onAppear { risen = true }
        .sensoryFeedback(.selection, trigger: swaps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("這一組照片")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("點兩下開始整理")
        .accessibilityAction(.default, onOpen)
        .accessibilityAction(named: "下一張") { sendBack() }
    }

    // MARK: - 拖動

    /// 拖一小段之後像橡皮筋：拖再遠也最多跑 160pt，卡片不會被拉出畫面
    private func rubber(_ d: CGSize) -> CGSize {
        CGSize(width: 160 * tanh(d.width / 160), height: 160 * tanh(d.height / 160))
    }

    /// 最少移動 6pt 才算拖，不然就是點一下（點一下是開始整理）
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                drag = value.translation
            }
            .onEnded { value in
                let far = hypot(value.translation.width, value.translation.height)
                let speed = hypot(value.velocity.width, value.velocity.height)
                // 拖夠遠，或甩得夠快（每秒 600pt，而且至少動了 24pt）：送到後面
                if far > 70 || (speed > 600 && far > 24) {
                    sendBack()
                } else {
                    // 不夠遠：彈回前面的位置
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { drag = .zero }
                }
            }
    }

    /// 放手的位置和送到後面在同一個動畫裡：從手放開的地方直接退到後面，
    /// 不會先彈回中間再走
    private func sendBack() {
        guard cards.count > 1 else {
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { drag = .zero }
            return
        }
        // 0.6 秒、不回彈的減速，跟原作的 cubic-bezier(0.22, 1, 0.36, 1) 差不多
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.6)) {
            drag = .zero
            onSendBack()
        }
        swaps += 1
    }

    // MARK: - 浮上來

    /// 從畫面底下浮上來；減少動態效果時原地淡入
    private func startY(in size: CGSize) -> CGFloat {
        reduceMotion ? 0 : size.height
    }

    /// 用不同長度的彈簧錯開，不用固定延遲
    private func animation(for depth: Int) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.2) }
        return .spring(duration: 0.55 + 0.12 * Double(min(depth, 3)), bounce: 0.28)
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
