import SwiftUI
import SwiftData
import Photos

/// 照片頁首頁：抽好的一組攤成扇子，點一下進入整理
struct PhotosView: View {
    let isLimited: Bool

    @Environment(DeletionQueue.self) private var queue
    @Environment(IslandModel.self) private var island
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.groupSize) private var groupSize = SettingsDefault.groupSize
    @AppStorage(SettingsKey.excludeViewed) private var excludeViewed = true
    @AppStorage(SettingsKey.excludeFavorites) private var excludeFavorites = true
    @AppStorage(SettingsKey.photoFilter) private var filterRaw = MediaFilter.photos.rawValue

    @Namespace private var namespace
    @State private var deck = PhotoDeckModel()
    @State private var entered = false
    @State private var includeViewedOnce = false
    @State private var showReview = false

    private var filter: MediaFilter {
        MediaFilter(rawValue: filterRaw).flatMap { MediaFilter.photoFilters.contains($0) ? $0 : nil } ?? .photos
    }

    var body: some View {
        VStack(spacing: 12) {
            if isLimited {
                LimitedAccessBanner()
                    .padding(.horizontal)
            }
            content
        }
        .background { Backdrop(asset: deck.current) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbarColorScheme(.dark, for: .tabBar)
        // 用全螢幕蓋上去（不是 push）：分頁列、導覽列不用藏起來再出現，返回時排版不會跳
        .fullScreenCover(isPresented: $entered) {
            PhotoDeckView(deck: deck, onGroupDone: groupDone)
                .environment(queue)
                .environment(island)
                .environment(\.modelContext, context)
                .navigationTransition(.zoom(sourceID: FanView.transitionID, in: namespace))
        }
        .task {
            if deck.generation == 0 { await reload() }
        }
        .onChange(of: filterRaw) {
            Task { await reload() }
        }
        .onChange(of: deck.current?.localIdentifier) {
            ImageLoader.shared.preheat(deck.neighbors, targetSize: CardStack.targetSize)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sweepAssetsDeleted)) { note in
            if let ids = note.userInfo?["ids"] as? Set<String> {
                withAnimation(.snappy) { deck.removeDeleted(ids) }
            }
        }
        .sheet(isPresented: $showReview) {
            DeleteReviewView()
        }
    }

    // MARK: - 內容

    @ViewBuilder
    private var content: some View {
        switch deck.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView("沒有\(filter.title)", systemImage: filter.systemImage,
                                   description: Text(excludeFavorites ? "「我的最愛」不會抽到，可以在設定裡改。" : "換個分類看看。"))
        case .allViewed:
            ContentUnavailableView {
                Label("\(filter.title)都看過了", systemImage: "checkmark.circle")
            } description: {
                Text("重設瀏覽記錄後，看過的會重新回到隨機池。")
            } actions: {
                Button("重設瀏覽記錄") {
                    StatsRecorder.resetViewed(context: context)
                    Task { await reload() }
                }
                .buttonStyle(.borderedProminent)
                Button("這次也抽看過的") {
                    includeViewedOnce = true
                    Task { await reload() }
                }
            }
        case .ready, .finished:
            FanView(cards: deck.visible, namespace: namespace) {
                guard deck.phase == .ready else { return }
                entered = true
            }
            // 換組時重新從底部浮上來
            .id(deck.generation)
        }
    }

    // MARK: - 工具列

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("分類", selection: $filterRaw) {
                    ForEach(MediaFilter.photoFilters) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item.rawValue)
                    }
                }
                Picker(selection: $groupSize) {
                    ForEach(SettingsDefault.groupSizes, id: \.self) { size in
                        Text("\(size.formatted()) 張").tag(size)
                    }
                } label: {
                    Label("每組數量", systemImage: "square.stack")
                    Text("\(groupSize.formatted()) 張")
                }
                .pickerStyle(.menu)
                Button("重抽一組", systemImage: "shuffle") {
                    Task { await reload() }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(filter.title)
                        .fontWeight(.semibold)
                    if deck.phase == .ready {
                        Text(deck.remaining.formatted())
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.2), in: .capsule)
                            .contentTransition(.numericText())
                    }
                }
                .fixedSize()
            }
        }
        if queue.count > 0 {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showReview = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text(queue.count.formatted())
                            .contentTransition(.numericText())
                    }
                }
                .accessibilityLabel("待刪除 \(queue.count) 項")
            }
        }
    }

    // MARK: - 動作

    private func reload() async {
        let includeViewed = includeViewedOnce
        includeViewedOnce = false
        await deck.load(filter: filter, size: groupSize,
                        excludeViewed: excludeViewed && !includeViewed,
                        excludeFavorites: excludeFavorites,
                        pending: queue.ids, context: context)
    }

    /// 一組看完：回到首頁，下一組浮上來
    private func groupDone() {
        entered = false
        Task { await reload() }
    }
}

/// 只給了部分照片權限
private struct LimitedAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("只開放了部分照片，抽不到其他的。")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("改成完整取用") { AppLinks.openSettings() }
                .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

#Preview("深色") {
    NavigationStack {
        PhotosView(isLimited: true)
    }
    .environment(DeletionQueue())
    .environment(IslandModel())
    .environment(\.colorScheme, .dark)
    .modelContainer(PreviewData.container)
}

#Preview("淺色") {
    NavigationStack {
        PhotosView(isLimited: false)
    }
    .environment(DeletionQueue())
    .environment(IslandModel())
    .modelContainer(PreviewData.container)
}
