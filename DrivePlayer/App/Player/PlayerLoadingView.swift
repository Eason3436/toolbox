import SwiftUI
import UIKit

/// 載入畫面要顯示的東西
struct PlayerLoading: Equatable {
    var title: String
    var subtitle: String?
    var logoURL: URL?
    var backdropURL: URL?
}

/// 載入到哪裡：每一段有起點，等下一段時慢慢往上限爬（看得出來有在動），到了下一段再接上去
enum LoadingStage {
    /// 代理讀檔頭（TrueHD 要先解一點拿格式）
    case connecting
    /// 播放器開始讀
    case buffering
    /// 可以播了，等第一個畫面
    case ready
    /// 開始播：填滿、淡出
    case playing

    var floor: Double {
        switch self {
        case .connecting: 0.06
        case .buffering: 0.4
        case .ready: 0.72
        case .playing: 1
        }
    }

    var ceiling: Double {
        switch self {
        case .connecting: 0.36
        case .buffering: 0.68
        case .ready: 0.95
        case .playing: 1
        }
    }
}

@MainActor
@Observable
final class PlayerLoadingModel {
    var info: PlayerLoading?
    var visible = false
    private var from = 0.0
    private var floor = 0.0
    private var ceiling = 0.0
    private var changedAt = Date()

    func reset() {
        from = 0
        floor = 0
        ceiling = 0
        changedAt = .now
    }

    func set(_ stage: LoadingStage) {
        let now = Date()
        from = progress(at: now)
        floor = max(stage.floor, from)
        ceiling = max(stage.ceiling, floor)
        changedAt = now
    }

    /// 從上一段顯示的位置平滑接到這一段，再往上限慢慢爬
    func progress(at date: Date) -> Double {
        let t = max(0, date.timeIntervalSince(changedAt))
        let target = floor + (ceiling - floor) * (1 - exp(-t / 3))
        return min(1, target + (from - target) * exp(-t / 0.22))
    }
}

/// 播放前的載入畫面：模糊的背景，中間是片名 logo，logo 本身就是進度條（從 leading 往 trailing 亮起來）
struct PlayerLoadingView: View {
    let model: PlayerLoadingModel
    let onClose: () -> Void
    @State private var logo: UIImage?
    @State private var backdrop: UIImage?

    var body: some View {
        let info = model.info
        ZStack {
            Color.black.ignoresSafeArea()
            if let backdrop {
                Image(uiImage: backdrop)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 28)
                    .opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            TimelineView(.animation(paused: !model.visible)) { context in
                let progress = model.progress(at: context.date)
                VStack(spacing: 14) {
                    FillingLogo(image: logo, title: info?.title ?? "", waitingForImage: info?.logoURL != nil && logo == nil,
                                progress: progress)
                    if let subtitle = info?.subtitle {
                        Text(subtitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("正在載入\(info?.title ?? "")")
                .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
            }
            .padding(40)
        }
        .overlay(alignment: .topLeading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .closeButtonBackground()
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.top, 8)
            .accessibilityLabel("關閉")
        }
        .opacity(model.visible ? 1 : 0)
        .environment(\.colorScheme, .dark)
        .task(id: info?.logoURL) {
            logo = info?.logoURL.flatMap { ImageCache.shared.cached($0) }
            guard logo == nil, let url = info?.logoURL else { return }
            let loaded = await ImageCache.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) { logo = loaded }
        }
        .task(id: info?.backdropURL) {
            backdrop = info?.backdropURL.flatMap { ImageCache.shared.cached($0) }
            guard backdrop == nil, let url = info?.backdropURL else { return }
            let loaded = await ImageCache.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.3)) { backdrop = loaded }
        }
    }
}

/// 暗的 logo 上面疊亮的 logo，亮的那層只露出進度的寬度
private struct FillingLogo: View {
    let image: UIImage?
    let title: String
    /// logo 還在下載：先留位置，不閃片名
    let waitingForImage: Bool
    let progress: Double

    var body: some View {
        content
            .saturation(0)
            .opacity(0.25)
            .overlay {
                content
                    .mask(alignment: .leading) {
                        GeometryReader { proxy in
                            Rectangle().frame(width: proxy.size.width * progress)
                        }
                    }
            }
            .shadow(color: .black.opacity(0.35), radius: 12)
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300, maxHeight: 130)
        } else if waitingForImage {
            Color.clear.frame(width: 240, height: 90)
        } else {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: 320)
        }
    }
}

private extension View {
    @ViewBuilder
    func closeButtonBackground() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }
}
