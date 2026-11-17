import SwiftUI
import Photos

/// 疊在一起的卡片。只有最上面那張能拖。
struct CardStack: View {
    let deck: PhotoDeckModel
    let onMark: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onOpen: (PHAsset) -> Void

    @Environment(DeletionQueue.self) private var queue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 正在拖的那張（用 ID 綁，飛出去的卡被拿掉時不會影響下一張）
    @State private var activeID: String?
    @State private var drag: CGSize = .zero
    /// 往回走時新出現的卡從前緣滑進來
    @State private var goingBack = false

    /// 跟 iPhone 17 Pro Max 卡片差不多大的像素
    static let targetSize = CGSize(width: 1290, height: 2000)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                ForEach(deck.visible) { card in
                    cardView(card, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .gesture(dragGesture(size: size))
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            Button("加入待刪除", action: onMark)
            Button("下一張", action: onNext)
            if deck.canGoBack {
                Button("上一張", action: back)
            }
        }
    }

    // MARK: - 卡片

    private func cardView(_ card: DeckCard, size: CGSize) -> some View {
        let isTop = card.depth == 0
        let offset = card.id == activeID ? drag : .zero
        let progress = isTop ? deleteProgress(size: size) : 0
        let depth = CGFloat(card.depth)

        return AssetImage(asset: card.asset, targetSize: Self.targetSize)
            .frame(width: size.width, height: size.height)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 28))
            .overlay {
                // 往上拖時慢慢變紅、出現垃圾桶
                RoundedRectangle(cornerRadius: 28)
                    .fill(.red.opacity(0.35 * progress))
                    .overlay {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 56, weight: .semibold))
                            .foregroundStyle(.white)
                            .opacity(progress)
                            .scaleEffect(0.7 + 0.3 * progress)
                    }
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if isTop { badges(for: card.asset) }
            }
            .shadow(color: .black.opacity(isTop ? 0.18 : 0.08), radius: 16, y: 8)
            .scaleEffect(1 - depth * 0.05)
            .offset(y: depth * 18)
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width) / 28), anchor: .bottom)
            .zIndex(-Double(card.depth))
            .allowsHitTesting(isTop)
            .onTapGesture { onOpen(card.asset) }
            .transition(.asymmetric(
                insertion: goingBack && !reduceMotion ? .move(edge: .leading).combined(with: .opacity) : .opacity,
                removal: .opacity
            ))
            .accessibilityElement()
            .accessibilityLabel(RelativeDay.text(for: card.asset.takenAt))
            .accessibilityHidden(!isTop)
    }

    /// 原況照片、動圖、已經在待刪除
    @ViewBuilder
    private func badges(for asset: PHAsset) -> some View {
        HStack(spacing: 6) {
            if asset.mediaSubtypes.contains(.photoLive) {
                Label("原況", systemImage: "livephoto")
            }
            if asset.playbackStyle == .imageAnimated {
                Label("GIF", systemImage: "square.stack.3d.forward.dottedline")
            }
            if asset.isFavorite {
                Label("最愛", systemImage: "heart.fill")
            }
            if queue.contains(asset.localIdentifier) {
                Button {
                    withAnimation(.snappy) { queue.remove(asset.localIdentifier) }
                } label: {
                    Label("待刪除・點一下保留", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .font(.caption.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(14)
    }

    // MARK: - 手勢

    private func deleteProgress(size: CGSize) -> Double {
        guard abs(drag.height) > abs(drag.width), drag.height < 0 else { return 0 }
        return min(Double(-drag.height / (size.height * 0.25)), 1)
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard let top = deck.current else { return }
                if activeID != top.localIdentifier {
                    activeID = top.localIdentifier
                    goingBack = false
                }
                var t = value.translation
                // 往下拖給一點阻力（往下沒有動作）
                if t.height > 0 { t.height = t.height / 4 }
                drag = t
            }
            .onEnded { value in
                let t = value.translation
                let p = value.predictedEndTranslation
                let vertical = abs(t.height) > abs(t.width)
                if vertical, t.height < -size.height * 0.22 || p.height < -size.height * 0.6 {
                    fly(to: CGSize(width: t.width, height: -size.height * 1.5), then: onMark)
                } else if !vertical, t.width < -size.width * 0.3 || p.width < -size.width * 0.8 {
                    fly(to: CGSize(width: -size.width * 1.6, height: t.height), then: onNext)
                } else if !vertical, deck.canGoBack, t.width > size.width * 0.3 || p.width > size.width * 0.8 {
                    withAnimation(.snappy) { drag = .zero }
                    back()
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { drag = .zero }
                }
            }
    }

    /// 卡片飛出去，飛完再換下一張
    private func fly(to target: CGSize, then action: @escaping () -> Void) {
        goingBack = false
        withAnimation(.easeIn(duration: reduceMotion ? 0.12 : 0.2)) {
            drag = target
        } completion: {
            action()
        }
    }

    private func back() {
        goingBack = true
        onPrevious()
    }
}
