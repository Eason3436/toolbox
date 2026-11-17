import SwiftUI
import Photos

/// 同一天拍的照片
struct DayGroup: Identifiable {
    let day: Date
    let assets: [PHAsset]
    var id: Date { day }
}

/// 找這張照片前後幾天的照片，依天分組
enum NearbyDays {
    static func load(around date: Date, days: Int = 3, calendar: Calendar = .current) async -> [DayGroup] {
        await Task.detached(priority: .userInitiated) {
            let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: date)) ?? date
            let end = calendar.date(byAdding: .day, value: days + 1, to: calendar.startOfDay(for: date)) ?? date
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate < %@",
                                            PHAssetMediaType.image.rawValue, start as NSDate, end as NSDate)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let result = PHAsset.fetchAssets(with: options)
            var assets: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
            return group(assets, calendar: calendar)
        }.value
    }

    nonisolated static func group(_ assets: [PHAsset], calendar: Calendar) -> [DayGroup] {
        let byDay = Dictionary(grouping: assets) { calendar.startOfDay(for: $0.takenAt) }
        return byDay.keys.sorted().map { DayGroup(day: $0, assets: byDay[$0] ?? []) }
    }
}

/// 照片上兩指捏小：看這張照片前後幾天的照片。左右滑換一天，點一下照片放進待刪除。
struct DayGridView: View {
    let anchor: PHAsset
    let onClose: () -> Void

    @Environment(DeletionQueue.self) private var queue
    @AppStorage(SettingsKey.hapticsOn) private var hapticsOn = true

    @State private var groups: [DayGroup] = []
    @State private var page: Date?
    @State private var loaded = false
    /// 這裡標記的順序（復原用）
    @State private var marks: [String] = []
    @State private var markTick = 0

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !loaded {
                ProgressView()
            } else if groups.isEmpty {
                Text("這幾天沒有其他照片").foregroundStyle(.secondary)
            } else {
                pager
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        // 兩指撐開回到原本那張
        .simultaneousGesture(
            MagnifyGesture().onEnded { value in
                if value.magnification > 1.25 { onClose() }
            }
        )
        .task {
            groups = await NearbyDays.load(around: anchor.takenAt)
            page = Calendar.current.startOfDay(for: anchor.takenAt)
            loaded = true
        }
        .sensoryFeedback(.selection, trigger: markTick) { _, _ in hapticsOn }
    }

    // MARK: - 分頁

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(groups) { group in
                    dayPage(group)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
    }

    private func dayPage(_ group: DayGroup) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(group.assets, id: \.localIdentifier) { asset in
                        tile(asset)
                            .id(asset.localIdentifier)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if group.assets.contains(where: { $0.localIdentifier == anchor.localIdentifier }) {
                    proxy.scrollTo(anchor.localIdentifier, anchor: .center)
                }
            }
        }
    }

    private func tile(_ asset: PHAsset) -> some View {
        let id = asset.localIdentifier
        let marked = queue.contains(id)
        return Button {
            toggle(asset)
        } label: {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    AssetImage(asset: asset, targetSize: CGSize(width: 400, height: 540))
                }
                .clipShape(.rect(cornerRadius: 20))
                .overlay {
                    if marked {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.red.opacity(0.35))
                        Image(systemName: "trash.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 4)
                    }
                }
                .overlay {
                    // 剛剛看的那張框起來
                    if id == anchor.localIdentifier {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.takenAt.formatted(date: .omitted, time: .shortened))
        .accessibilityValue(marked ? "待刪除" : "")
        .accessibilityHint(marked ? "點兩下保留" : "點兩下放進待刪除")
    }

    // MARK: - 下方

    private var bottomBar: some View {
        HStack(spacing: 14) {
            CircleButton(title: "關閉", systemImage: "xmark", action: onClose)

            VStack(spacing: 6) {
                Text((page ?? anchor.takenAt).formatted(date: .numeric, time: .omitted))
                    .font(.headline.monospacedDigit())
                    .contentTransition(.numericText())
                if groups.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(groups) { group in
                            Circle()
                                .fill(group.day == page ? Color.white : Color.white.opacity(0.35))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .glassEffect(.regular, in: .capsule)
            .animation(.snappy, value: page)

            CircleButton(title: "復原", systemImage: "arrow.uturn.backward") { undo() }
                .disabled(marks.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - 動作

    private func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        withAnimation(.snappy(duration: 0.2)) {
            if queue.contains(id) {
                queue.remove(id)
                marks.removeAll { $0 == id }
            } else {
                let kind: StatsKind = asset.mediaSubtypes.contains(.photoScreenshot) ? .screenshot : .photo
                queue.add(id, kind: kind, isVideo: false)
                marks.append(id)
            }
        }
        markTick += 1
    }

    private func undo() {
        guard let id = marks.popLast() else { return }
        withAnimation(.snappy(duration: 0.2)) { queue.remove(id) }
        markTick += 1
    }
}
