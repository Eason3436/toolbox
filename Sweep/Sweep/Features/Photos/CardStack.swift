import SwiftUI
import Photos

/// 整理中的卡片。往左下一張、往右上一張；按住往上拖動態島會變大，放開就被吸進動態島。
struct CardStack: View {
    let deck: PhotoDeckModel
    let onMark: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onOpen: (PHAsset) -> Void

    @Environment(DeletionQueue.self) private var queue
    @Environment(IslandModel.self) private var island
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKey.hapticsOn) private var hapticsOn = true

    /// 正在拖的那張（用 ID 綁，飛出去的卡被拿掉時不會影響下一張）
    @State private var activeID: String?
    @State private var drag: CGSize = .zero
    /// 正在被吸進動態島
    @State private var swallowing = false
    /// 拖到放開就會刪除的位置（觸覺回饋用）
    @State private var armed = false
    /// 往回走時新出現的卡從前緣滑進來
    @State private var goingBack = false

    /// 跟 iPhone 17 Pro Max 卡片差不多大的像素
    static let targetSize = CGSize(width: 1290, height: 2000)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let frame = geo.frame(in: .global)
            ZStack {
                ForEach(deck.visible) { card in
                    cardView(card, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(.rect)
            .gesture(dragGesture(size: size, frame: frame))
        }
        .sensoryFeedback(.impact(weight: .light), trigger: armed) { old, new in
            hapticsOn && new && !old
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
        let isActive = card.id == activeID
        let offset = isActive ? drag : .zero
        let fitted = Self.fit(card.asset, in: size)

        return AssetImage(asset: card.asset, targetSize: Self.targetSize)
            .frame(width: fitted.width, height: fitted.height)
            .background(.white.opacity(0.08))
            .clipShape(.rect(cornerRadius: 22))
            .overlay(alignment: .topLeading) {
                if isTop && !swallowing { badges(for: card.asset) }
            }
            .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            .scaleEffect(scale(depth: card.depth, isActive: isActive, size: size))
            .opacity(opacity(depth: card.depth, isActive: isActive))
            .offset(offset)
            .rotationEffect(.degrees(isActive && !swallowing ? Double(offset.width) / 30 : 0), anchor: .bottom)
            .zIndex(-Double(card.depth))
            .allowsHitTesting(isTop)
            .onTapGesture { onOpen(card.asset) }
            .transition(insertion)
            .accessibilityElement()
            .accessibilityLabel(RelativeDay.text(for: card.asset.takenAt))
            .accessibilityHidden(!isTop)
    }

    /// 照片原本的比例，塞進可用空間
    static func fit(_ asset: PHAsset, in size: CGSize) -> CGSize {
        let w = CGFloat(max(asset.pixelWidth, 1))
        let h = CGFloat(max(asset.pixelHeight, 1))
        let scale = min(size.width / w, size.height / h)
        return CGSize(width: w * scale, height: h * scale)
    }

    private func scale(depth: Int, isActive: Bool, size: CGSize) -> CGFloat {
        if depth == 0 {
            guard isActive else { return 1 }
            if swallowing { return 0.04 }
            // 往上拖時慢慢縮小，像被吸走
            return 1 - 0.22 * deleteProgress(size: size)
        }
        // 下一張藏在後面，拖得越遠越大
        return 0.9 + 0.1 * revealProgress(size: size)
    }

    private func opacity(depth: Int, isActive: Bool) -> Double {
        if depth >= 2 { return 0 }
        if depth == 0, isActive, swallowing { return 0.3 }
        return 1
    }

    /// 往回走時從前緣滑進來，其他時候淡入
    private var insertion: AnyTransition {
        let enter: AnyTransition
        if goingBack && !reduceMotion {
            enter = AnyTransition.move(edge: .leading).combined(with: AnyTransition.opacity)
        } else {
            enter = AnyTransition.opacity
        }
        return AnyTransition.asymmetric(insertion: enter, removal: AnyTransition.opacity)
    }

    /// 原況照片、動圖、已經在待刪除
    @ViewBuilder
    private func badges(for asset: PHAsset) -> some View {
        let live = asset.mediaSubtypes.contains(.photoLive)
        let gif = asset.playbackStyle == .imageAnimated
        let pending = queue.contains(asset.localIdentifier)
        if live || gif || pending {
            HStack(spacing: 6) {
                if live {
                    Label("原況", systemImage: "livephoto")
                }
                if gif {
                    Label("GIF", systemImage: "square.stack.3d.forward.dottedline")
                }
                if pending {
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
            .padding(12)
        }
    }

    // MARK: - 手勢

    /// 往上拖到四分之一高就算到位
    private func deleteProgress(size: CGSize) -> CGFloat {
        guard abs(drag.height) > abs(drag.width), drag.height < 0 else { return 0 }
        return min(-drag.height / (size.height * 0.25), 1)
    }

    private func revealProgress(size: CGSize) -> CGFloat {
        let horizontal = abs(drag.width) / (size.width * 0.5)
        let vertical = -drag.height / (size.height * 0.4)
        return min(max(horizontal, vertical, 0), 1)
    }

    private func dragGesture(size: CGSize, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard let top = deck.current else { return }
                if activeID != top.localIdentifier {
                    activeID = top.localIdentifier
                    swallowing = false
                    goingBack = false
                }
                guard !swallowing else { return }
                var t = value.translation
                // 往下拖給一點阻力（往下沒有動作）
                if t.height > 0 { t.height = t.height / 4 }
                drag = t
                let progress = deleteProgress(size: size)
                island.track(progress)
                armed = progress >= 1
            }
            .onEnded { value in
                guard !swallowing else { return }
                let t = value.translation
                let p = value.predictedEndTranslation
                let vertical = abs(t.height) > abs(t.width)
                armed = false
                if vertical, t.height < -size.height * 0.25 || p.height < -size.height * 0.6 {
                    swallow(size: size, frame: frame)
                    return
                }
                island.release()
                if !vertical, t.width < -size.width * 0.3 || p.width < -size.width * 0.8 {
                    fly(to: CGSize(width: -size.width * 1.6, height: t.height), then: onNext)
                } else if !vertical, deck.canGoBack, t.width > size.width * 0.3 || p.width > size.width * 0.8 {
                    withAnimation(.snappy) { drag = .zero }
                    back()
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { drag = .zero }
                }
            }
    }

    /// 吸進動態島：卡片縮小飛到動態島中心，到了動態島鼓一下
    private func swallow(size: CGSize, frame: CGRect) {
        guard let islandFrame = IslandMetrics.frame, !reduceMotion else {
            // 沒有動態島（或減少動態效果）：往上飛出去
            island.release()
            fly(to: CGSize(width: drag.width, height: -size.height * 1.5), then: onMark)
            return
        }
        let target = CGSize(width: islandFrame.midX - frame.midX,
                            height: islandFrame.midY - frame.midY)
        withAnimation(.spring(duration: 0.32, bounce: 0)) {
            swallowing = true
            drag = target
            island.track(1)
        } completion: {
            onMark()
            island.gulp(count: queue.count)
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
