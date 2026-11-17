import SwiftUI
import SwiftData
import Photos

/// 刪除確認：待刪除的縮圖格子，點一下改成保留，按下去才一次刪掉
struct DeleteReviewView: View {
    @Environment(DeletionQueue.self) private var queue
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.hapticsOn) private var hapticsOn = true

    /// 取消勾選（要保留）的
    @State private var kept: Set<String> = []
    @State private var assets: [String: PHAsset] = [:]
    @State private var totalBytes: Int64?
    @State private var deletedTick = 0

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    private var selected: [DeletionQueue.Item] {
        queue.items.filter { !kept.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if queue.items.isEmpty {
                    ContentUnavailableView("沒有待刪除的項目", systemImage: "trash.slash",
                                           description: Text("往上甩的照片、按了刪除的影片會放在這裡。"))
                } else {
                    ScrollView {
                        Text("點一下可以改成保留。刪掉的會先放到「最近刪除」，30 天內救得回來。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(queue.items) { item in
                                tile(item)
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom) { deleteBar }
                }
            }
            .navigationTitle("待刪除")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉", systemImage: "xmark") { dismiss() }
                }
                if !queue.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(kept.isEmpty ? "全部保留" : "全部刪除") {
                            withAnimation(.snappy) {
                                kept = kept.isEmpty ? Set(queue.items.map(\.id)) : []
                            }
                        }
                    }
                }
            }
        }
        .task(id: queue.items.map(\.id)) {
            let ids = queue.items.map(\.id)
            var map: [String: PHAsset] = [:]
            for asset in PhotoLibrary.assets(for: ids) { map[asset.localIdentifier] = asset }
            assets = map
        }
        .task(id: selected.map(\.id)) {
            totalBytes = nil
            let list = selected.compactMap { assets[$0.id] }
            guard !list.isEmpty else { return }
            totalBytes = await Task.detached(priority: .utility) {
                list.reduce(Int64(0)) { $0 + PhotoLibrary.fileSize(of: $1) }
            }.value
        }
        .sensoryFeedback(.success, trigger: deletedTick) { _, _ in hapticsOn }
        .sensoryFeedback(.selection, trigger: kept) { _, _ in hapticsOn }
    }

    private func tile(_ item: DeletionQueue.Item) -> some View {
        let isKept = kept.contains(item.id)
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isKept { kept.remove(item.id) } else { kept.insert(item.id) }
            }
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let asset = assets[item.id] {
                        AssetImage(asset: asset, targetSize: CGSize(width: 320, height: 320))
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .clipped()
                .overlay {
                    if isKept {
                        Color.black.opacity(0.45)
                        Text("保留")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.isVideo, let asset = assets[item.id] {
                        Label(Duration.seconds(asset.duration).formatted(.time(pattern: .minuteSecond)), systemImage: "video.fill")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isKept ? "circle" : "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .padding(6)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isKept ? "保留" : "要刪除")
        .accessibilityHint("點兩下切換")
    }

    private var deleteBar: some View {
        VStack(spacing: 6) {
            if selected.isEmpty {
                Button {
                    withAnimation(.snappy) { queue.remove(kept) }
                    kept = []
                    dismiss()
                } label: {
                    Text("全部保留")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
            } else {
                Button(role: .destructive) {
                    Task { await commit() }
                } label: {
                    HStack {
                        if queue.isDeleting {
                            ProgressView()
                        }
                        Text("刪除 \(selected.count.formatted()) 項")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(queue.isDeleting)
                Text(totalBytes.map { "可以騰出約 \($0.formatted(.byteCount(style: .file)))" } ?? " ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func commit() async {
        let ok = await queue.commit(selected, keep: kept, context: context)
        if ok {
            deletedTick += 1
            kept = []
            dismiss()
        }
    }
}

#Preview("淺色") {
    DeleteReviewView()
        .environment(DeletionQueue())
        .modelContainer(PreviewData.container)
}

#Preview("深色") {
    DeleteReviewView()
        .environment(DeletionQueue())
        .modelContainer(PreviewData.container)
        .preferredColorScheme(.dark)
}
