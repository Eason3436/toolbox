import SwiftUI
import SwiftData
import Photos

/// 整理中：上面返回、進度、分享；中間卡片；下面收藏、時間地點、復原
struct PhotoDeckView: View {
    let deck: PhotoDeckModel
    /// 這組看完（也處理完待刪除）時呼叫，回到首頁抽下一組
    let onGroupDone: () -> Void

    @Environment(DeletionQueue.self) private var queue
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.hapticsOn) private var hapticsOn = true

    @State private var showReview = false
    /// 翻到背面看資訊的那張
    @State private var flippedID: String?
    /// 兩指捏小時打開的「前後幾天」
    @State private var dayAnchor: AssetRef?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var place: String?
    @State private var favorites: [String: Bool] = [:]
    @State private var shareURL: URL?
    @State private var exporting = false

    // 觸覺回饋的觸發器
    @State private var markTick = 0
    @State private var moveTick = 0
    @State private var undoTick = 0
    @State private var favoriteTick = 0
    @State private var flipTick = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 4)
            Group {
                if deck.phase == .ready {
                    CardStack(
                        deck: deck,
                        onMark: mark,
                        onNext: next,
                        onPrevious: previous,
                        flippedID: $flippedID,
                        onFlip: flip,
                        onZoomOut: zoomOut
                    )
                } else {
                    // 看完了，馬上會回首頁或跳出刪除確認
                    Label("這組看完了", systemImage: "checkmark.circle")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            bottomBar
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        .background { Backdrop(asset: deck.current) }
        .environment(\.colorScheme, .dark)
        .overlay {
            if let ref = dayAnchor {
                DayGridView(anchor: ref.asset) {
                    withAnimation(.snappy) { dayAnchor = nil }
                }
                .environment(\.colorScheme, .dark)
                .transition(.opacity.combined(with: .scale(scale: 1.06)))
            }
        }
        .overlay {
            // 往上拖刪除時，蓋在動態島上的黑色膠囊（要在全螢幕這一層才看得到）
            IslandOverlay()
        }
        .onChange(of: deck.current?.localIdentifier, initial: true) { _, id in
            flippedID = nil
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
                onGroupDone()
            }
        }
        .sheet(isPresented: $showReview, onDismiss: {
            if deck.phase == .finished { onGroupDone() }
        }) {
            DeleteReviewView()
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: markTick) { _, _ in hapticsOn }
        .sensoryFeedback(.selection, trigger: moveTick) { _, _ in hapticsOn }
        .sensoryFeedback(.impact(weight: .light), trigger: undoTick) { _, _ in hapticsOn }
        .sensoryFeedback(.success, trigger: favoriteTick) { _, _ in hapticsOn }
        .sensoryFeedback(.selection, trigger: flipTick) { _, _ in hapticsOn }
    }

    // MARK: - 上方

    private var topBar: some View {
        HStack {
            CircleButton(title: "返回", systemImage: "chevron.backward") { dismiss() }

            Spacer()

            GroupProgress(value: deck.progress)
                .frame(width: 104)
                .accessibilityLabel("第 \(deck.position) 張，共 \(deck.assets.count) 張")

            Spacer()

            CircleButton(title: "分享", systemImage: "square.and.arrow.up", busy: exporting) { share() }
                .disabled(deck.current == nil)
        }
    }

    // MARK: - 下方

    private var bottomBar: some View {
        HStack(spacing: 14) {
            CircleButton(title: isFavorite ? "取消收藏" : "收藏",
                         systemImage: isFavorite ? "heart.fill" : "heart",
                         tint: isFavorite ? .pink : nil) { toggleFavorite() }
                .disabled(deck.current == nil)

            Button {
                flip()
            } label: {
                HStack(spacing: 10) {
                    VStack(spacing: 1) {
                        if let asset = deck.current {
                            Text(RelativeDay.text(for: asset.takenAt))
                                .font(.headline)
                            Text(place ?? asset.takenAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Image(systemName: flippedID == nil ? "info.circle.fill" : "photo.circle.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
                .padding(.trailing, 14)
                .frame(height: 58)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel(flippedID == nil ? "翻過來看資訊" : "翻回照片")
            .task(id: deck.current?.localIdentifier) {
                place = nil
                guard let location = deck.current?.location else { return }
                let found = await PlaceLookup.shared.place(for: location)?.short
                withAnimation(.easeOut(duration: 0.2)) { place = found }
            }

            CircleButton(title: "復原", systemImage: "arrow.uturn.backward") { undo() }
                .disabled(!deck.canUndo)
        }
    }

    private var isFavorite: Bool {
        guard let asset = deck.current else { return false }
        return favorites[asset.localIdentifier] ?? asset.isFavorite
    }

    // MARK: - 動作

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

    private func zoomOut() {
        guard let asset = deck.current else { return }
        withAnimation(.snappy) { dayAnchor = AssetRef(asset: asset) }
        flipTick += 1
    }

    /// 點照片或下面的膠囊：翻面看資訊，再點一下翻回來
    private func flip() {
        guard let id = deck.current?.localIdentifier else { return }
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0.15)
        withAnimation(animation) {
            flippedID = flippedID == id ? nil : id
        }
        flipTick += 1
    }

    private func toggleFavorite() {
        guard let asset = deck.current else { return }
        let id = asset.localIdentifier
        let newValue = !isFavorite
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
        guard let asset = deck.current, !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            shareURL = try? await PhotoLibrary.exportOriginal(asset)
        }
    }
}

/// 上方的進度條
private struct GroupProgress: View {
    let value: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.25))
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(.white)
                        .frame(width: geo.size.width * value)
                }
            }
            .animation(.snappy, value: value)
    }
}

/// 玻璃圓形按鈕
struct CircleButton: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint ?? .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(title)
    }
}
