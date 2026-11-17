import SwiftUI
import SwiftData
import AVFoundation
import Photos

/// 影片頁：全螢幕直向分頁，上下滑切換，自動循環播放
struct VideosView: View {
    let isActive: Bool

    @Environment(DeletionQueue.self) private var queue
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.excludeViewed) private var excludeViewed = true
    @AppStorage(SettingsKey.excludeFavorites) private var excludeFavorites = true
    @AppStorage(SettingsKey.hapticsOn) private var hapticsOn = true

    @State private var feed = VideoFeedModel()
    @State private var pool = PlayerPool()
    @State private var scrolledID: String?
    @State private var currentAsset: PHAsset?
    @State private var place: String?
    @State private var favorites: [String: Bool] = [:]
    @State private var showReview = false
    @State private var shareURL: URL?
    @State private var exporting = false

    /// 浮在影片上的玻璃加一點黑，亮的畫面也看得清楚
    static let glassTint = Color.black.opacity(0.35)

    @State private var markTick = 0
    @State private var favoriteTick = 0
    @State private var undoTick = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch feed.phase {
            case .loading:
                ProgressView()
            case .empty:
                ContentUnavailableView {
                    Label("沒有影片", systemImage: "video.slash")
                } description: {
                    Text(excludeViewed ? "影片都看過了，或相簿裡沒有影片。" : "相簿裡沒有影片。")
                } actions: {
                    if excludeViewed {
                        Button("重設瀏覽記錄") {
                            StatsRecorder.resetViewed(context: context)
                            Task { await reload() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .ready:
                // 讀安全區域：清楚的影片只放在狀態列和進度條之間，其他地方用模糊填滿
                GeometryReader { geo in
                    feedScroll(videoInsets: EdgeInsets(top: geo.safeAreaInsets.top, leading: 0,
                                                       bottom: geo.safeAreaInsets.bottom + Self.progressHeight, trailing: 0))
                    overlays
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .task {
            if feed.generation == 0 { await reload() }
        }
        .onChange(of: scrolledID) { _, id in
            focus(on: id)
        }
        .onChange(of: isActive, initial: true) { _, active in
            pool.setActive(active && scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            pool.setActive(isActive && phase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sweepAssetsDeleted)) { note in
            guard let ids = note.userInfo?["ids"] as? Set<String> else { return }
            let next = feed.removeDeleted(ids, current: scrolledID)
            if next != scrolledID {
                scrolledID = next
            }
        }
        .sheet(isPresented: $showReview) {
            DeleteReviewView()
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: markTick) { _, _ in hapticsOn }
        .sensoryFeedback(.success, trigger: favoriteTick) { _, _ in hapticsOn }
        .sensoryFeedback(.impact(weight: .light), trigger: undoTick) { _, _ in hapticsOn }
    }

    // MARK: - 捲動

    /// 進度條和它下面的留白
    private static let progressHeight: CGFloat = 24

    private func feedScroll(videoInsets: EdgeInsets) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(feed.ids, id: \.self) { id in
                    VideoPage(id: id, player: pool.player(for: id), insets: videoInsets)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .contentShape(.rect)
                        .onTapGesture { pool.togglePause() }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledID)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
    }

    // MARK: - 浮在上面的資訊與按鈕

    private var overlays: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Button("重新洗牌", systemImage: "shuffle") {
                        Task { await reload() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("影片").fontWeight(.semibold)
                        Text("\(feed.position(of: scrolledID).formatted())／\(feed.ids.count.formatted())")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(Self.glassTint).interactive(), in: .capsule)
                }
                Spacer()
                Button {
                    showReview = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        if queue.count > 0 {
                            Text(queue.count.formatted())
                                .contentTransition(.numericText())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(Self.glassTint).interactive(), in: .capsule)
                }
                .disabled(queue.count == 0)
                .accessibilityLabel("待刪除 \(queue.count) 項")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)

            if pool.isPaused {
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            HStack(alignment: .bottom, spacing: 12) {
                info
                    .frame(maxWidth: .infinity, alignment: .leading)
                rail
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            ProgressView(value: pool.progress)
                .progressViewStyle(.linear)
                .tint(.white)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .accessibilityLabel("播放進度")
        }
        .animation(.snappy, value: pool.isPaused)
    }

    /// 左下角：日期、地點、待刪除標記
    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let id = scrolledID, queue.contains(id) {
                Label("待刪除", systemImage: "trash.fill")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red, in: .capsule)
            }
            if let asset = currentAsset {
                Text(RelativeDay.text(for: asset.takenAt))
                    .font(.headline)
                Text(asset.takenAt.formatted(date: .long, time: .shortened))
                    .font(.subheadline)
                if let place {
                    Label(place, systemImage: "mappin")
                        .font(.subheadline)
                }
                Text(Duration.seconds(asset.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 6)
        .task(id: scrolledID) {
            place = nil
            guard let location = currentAsset?.location else { return }
            place = await PlaceLookup.shared.place(for: location)?.short
        }
    }

    /// 右側：收藏、分享、刪除、復原
    private var rail: some View {
        let id = scrolledID
        let pending = id.map(queue.contains) ?? false
        let favorite = id.flatMap { favorites[$0] } ?? currentAsset?.isFavorite ?? false

        return VStack(spacing: 18) {
            RailButton(title: favorite ? "已收藏" : "收藏",
                       systemImage: favorite ? "heart.fill" : "heart",
                       tint: favorite ? .pink : .white) {
                toggleFavorite()
            }
            RailButton(title: "分享", systemImage: "square.and.arrow.up", tint: .white, busy: exporting) {
                share()
            }
            RailButton(title: pending ? "保留" : "刪除",
                       systemImage: pending ? "arrow.uturn.backward.circle" : "trash",
                       tint: pending ? .white : .red) {
                if pending { keep() } else { mark() }
            }
            RailButton(title: "復原", systemImage: "arrow.uturn.backward", tint: .white) {
                undo()
            }
            .disabled(!feed.canUndo)
            .opacity(feed.canUndo ? 1 : 0.4)
        }
    }

    // MARK: - 動作

    private func reload() async {
        pool.releaseAll()
        await feed.load(excludeViewed: excludeViewed, excludeFavorites: excludeFavorites,
                        pending: queue.ids, context: context)
        scrolledID = feed.ids.first
        focus(on: scrolledID)
    }

    private func focus(on id: String?) {
        guard let id else {
            currentAsset = nil
            return
        }
        currentAsset = PhotoLibrary.asset(for: id)
        pool.focus(on: id, neighbors: feed.neighbors(of: id))
        StatsRecorder.recordViewed(id, kind: .video, context: context)
    }

    private func mark() {
        guard let id = scrolledID else { return }
        queue.add(id, kind: .video, isVideo: true)
        feed.recordMark(id)
        markTick += 1
        if let next = feed.id(after: id) {
            withAnimation(.snappy) { scrolledID = next }
        }
    }

    private func keep() {
        guard let id = scrolledID else { return }
        withAnimation(.snappy) { queue.remove(id) }
    }

    private func undo() {
        guard let id = feed.popMark() else { return }
        queue.remove(id)
        undoTick += 1
        withAnimation(.snappy) { scrolledID = id }
    }

    private func toggleFavorite() {
        guard let id = scrolledID else { return }
        let newValue = !(favorites[id] ?? currentAsset?.isFavorite ?? false)
        favorites[id] = newValue
        if newValue { favoriteTick += 1 }
        Task {
            do {
                try await PhotoLibrary.setFavorite(newValue, id: id)
            } catch {
                favorites[id] = !newValue
            }
        }
    }

    private func share() {
        guard let asset = currentAsset, !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            shareURL = try? await PhotoLibrary.exportOriginal(asset)
        }
    }
}

/// 一頁影片：還沒載好先顯示封面
private struct VideoPage: View {
    let id: String
    let player: AVQueuePlayer?
    /// 清楚的影片要避開的上下範圍（狀態列、進度條和分頁列）
    let insets: EdgeInsets

    @State private var asset: PHAsset?

    var body: some View {
        ZStack {
            // 上下（或左右）留黑邊的地方：同一支影片放大、模糊填滿。
            // 影片還沒出畫面前先用封面墊著
            if let asset {
                AssetImage(asset: asset, targetSize: CGSize(width: 120, height: 200), showsProgress: false)
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.3))
            }
            if let player {
                PlayerLayerView(player: player, fill: true, blurred: true)
            }
            // 原本比例放在中間
            ZStack {
                if let asset {
                    AssetImage(asset: asset, targetSize: CGSize(width: 600, height: 1000), contentMode: .fit, showsProgress: false)
                }
                if let player {
                    PlayerLayerView(player: player)
                }
            }
            .padding(insets)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(.black)
        .task(id: id) {
            asset = PhotoLibrary.asset(for: id)
        }
    }
}

/// 右側的一顆圓形按鈕＋文字
private struct RailButton: View {
    let title: String
    let systemImage: String
    var tint: Color
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if busy {
                        ProgressView()
                    } else {
                        Image(systemName: systemImage)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(tint)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 50, height: 50)
                // 影片很亮時也看得清楚：玻璃加深色、圖示和字加陰影
                .glassEffect(.regular.tint(VideosView.glassTint).interactive(), in: .circle)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                    .shadow(color: .black.opacity(0.4), radius: 8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// AVPlayerLayer
/// 同一個 AVPlayer 可以接好幾個 layer：前面一個完整顯示，後面一個放大填滿再模糊
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var fill = false
    var blurred = false

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        view.playerLayer.player = player
        view.backgroundColor = .clear
        view.clipsToBounds = true
        if blurred {
            let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
            effect.frame = view.bounds
            effect.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(effect)
        }
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

#Preview("深色") {
    VideosView(isActive: true)
        .environment(DeletionQueue())
        .modelContainer(PreviewData.container)
}

#Preview("淺色") {
    VideosView(isActive: true)
        .environment(DeletionQueue())
        .modelContainer(PreviewData.container)
        .preferredColorScheme(.light)
}
