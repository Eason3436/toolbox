import SwiftUI
import SwiftData
import Photos

/// 照片頁：隨機一組卡片，往左下一張、往右上一張、往上甩刪除
struct PhotosView: View {
    let isLimited: Bool

    @Environment(DeletionQueue.self) private var queue
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.groupSize) private var groupSize = SettingsDefault.groupSize
    @AppStorage(SettingsKey.excludeViewed) private var excludeViewed = true
    @AppStorage(SettingsKey.excludeFavorites) private var excludeFavorites = true
    @AppStorage(SettingsKey.hapticsOn) private var hapticsOn = true
    @AppStorage(SettingsKey.photoFilter) private var filterRaw = MediaFilter.photos.rawValue

    @State private var deck = PhotoDeckModel()
    @State private var includeViewedOnce = false
    @State private var showReview = false
    @State private var detail: AssetRef?
    @State private var place: String?

    // 觸覺回饋的觸發器
    @State private var markTick = 0
    @State private var moveTick = 0
    @State private var undoTick = 0

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            if deck.generation == 0 { await reload() }
        }
        .onChange(of: filterRaw) {
            Task { await reload() }
        }
        .onChange(of: deck.current?.localIdentifier, initial: true) { _, id in
            if let id {
                StatsRecorder.recordViewed(id, kind: deck.filter.statsKind, context: context)
            }
            ImageLoader.shared.preheat(deck.neighbors, targetSize: CardStack.targetSize)
        }
        .onChange(of: deck.phase) { _, phase in
            guard phase == .finished else { return }
            if queue.count > 0 {
                showReview = true
            } else {
                Task { await reload() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sweepAssetsDeleted)) { note in
            if let ids = note.userInfo?["ids"] as? Set<String> {
                withAnimation(.snappy) { deck.removeDeleted(ids) }
            }
        }
        .sheet(isPresented: $showReview, onDismiss: {
            // 這組看完、也處理完待刪除了，就抽下一組
            if deck.phase == .finished, queue.count == 0 {
                Task { await reload() }
            }
        }) {
            DeleteReviewView()
        }
        .sheet(item: $detail) { ref in
            PhotoDetailView(asset: ref.asset)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: markTick) { _, _ in hapticsOn }
        .sensoryFeedback(.selection, trigger: moveTick) { _, _ in hapticsOn }
        .sensoryFeedback(.impact(weight: .light), trigger: undoTick) { _, _ in hapticsOn }
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
        case .finished:
            finished
        case .ready:
            VStack(spacing: 16) {
                CardStack(
                    deck: deck,
                    onMark: mark,
                    onNext: next,
                    onPrevious: previous,
                    onOpen: { detail = AssetRef(asset: $0) }
                )
                .padding(.horizontal, 20)
                infoRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
    }

    private var finished: some View {
        ContentUnavailableView {
            Label("這組看完了", systemImage: "checkmark.circle")
        } description: {
            if queue.count > 0 {
                Text("有 \(queue.count.formatted()) 項等著刪除。")
            } else {
                Text("馬上抽下一組。")
            }
        } actions: {
            if queue.count > 0 {
                Button("檢查並刪除") { showReview = true }
                    .buttonStyle(.borderedProminent)
            }
            Button("下一組") { Task { await reload() } }
            if deck.canUndo {
                Button("復原上一步", systemImage: "arrow.uturn.backward") { undo() }
            }
        }
    }

    /// 卡片下方：復原、日期地點、詳情
    private var infoRow: some View {
        HStack(spacing: 12) {
            Button("復原", systemImage: "arrow.uturn.backward") { undo() }
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: .circle)
                .disabled(!deck.canUndo)

            VStack(spacing: 2) {
                if let asset = deck.current {
                    Text(caption(for: asset))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text(asset.takenAt.formatted(date: .long, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .task(id: deck.current?.localIdentifier) {
                place = nil
                guard let location = deck.current?.location else { return }
                place = await PlaceLookup.shared.place(for: location)?.short
            }

            Button("詳細資訊", systemImage: "info") {
                if let asset = deck.current { detail = AssetRef(asset: asset) }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 48, height: 48)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(deck.current == nil)
        }
    }

    private func caption(for asset: PHAsset) -> String {
        let day = RelativeDay.text(for: asset.takenAt)
        guard let place else { return day }
        return "\(day)・\(place)"
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
                HStack(spacing: 4) {
                    Text(filter.title)
                        .fontWeight(.semibold)
                    if deck.phase == .ready {
                        Text("剩 \(deck.remaining.formatted()) 張")
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
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
            }
            .disabled(queue.count == 0)
            .accessibilityLabel("待刪除 \(queue.count) 項")
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

    private func mark() {
        withAnimation(.snappy) { deck.markForDeletion(queue: queue) }
        markTick += 1
    }

    private func next() {
        withAnimation(.snappy) { deck.next() }
        moveTick += 1
    }

    private func previous() {
        withAnimation(.snappy) { deck.previous() }
        moveTick += 1
    }

    private func undo() {
        withAnimation(.snappy) { deck.undo(queue: queue) }
        undoTick += 1
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
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 14))
    }
}

#Preview("淺色") {
    NavigationStack {
        PhotosView(isLimited: true)
    }
    .environment(DeletionQueue())
    .modelContainer(PreviewData.container)
}

#Preview("深色") {
    NavigationStack {
        PhotosView(isLimited: false)
    }
    .environment(DeletionQueue())
    .modelContainer(PreviewData.container)
    .preferredColorScheme(.dark)
}
