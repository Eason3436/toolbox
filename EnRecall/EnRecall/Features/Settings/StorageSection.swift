import SwiftUI

/// 設定 → 儲存空間：一條分段長條＋下面的圖例（App 本體、單字與進度、PDF 講義、快取、其他）
struct StorageSection: View {
    @State private var usage: StorageUsage?
    @State private var isClearing = false
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        Section {
            if let usage {
                VStack(alignment: .leading, spacing: 14) {
                    StorageBar(slices: usage.slices)
                    FlowLayout(spacing: 16, lineSpacing: 10) {
                        ForEach(usage.slices) { slice in
                            StorageLegend(slice: slice)
                        }
                    }
                }
                .padding(.vertical, 6)
                .transition(.opacity)

                if usage.bytes(of: .caches) > 0 {
                    Button("清除快取", systemImage: "trash") {
                        clearCaches()
                    }
                    .disabled(isClearing)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        } header: {
            HStack {
                Text("儲存空間")
                Spacer()
                if let usage {
                    Text(usage.total, format: .byteCount(style: .file))
                        .monospacedDigit()
                }
            }
        } footer: {
            Text("快取是單字庫索引和暫存檔，清掉之後需要時會再下載、重建；單字和進度不受影響")
        }
        .listRowBackground(Color.er.surface)
        .animation(.easeOut(duration: 0.25), value: usage)
        .task { await refresh() }
    }

    private func refresh() async {
        usage = await Task.detached(priority: .utility) { StorageUsage.measure() }.value
    }

    private func clearCaches() {
        isClearing = true
        Task {
            await Task.detached(priority: .userInitiated) { StorageUsage.clearCaches() }.value
            await refresh()
            isClearing = false
            toasts.show("已清除快取", systemImage: "checkmark")
        }
    }
}

// MARK: - 計算

struct StorageUsage: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case app
        case data
        case documents
        case caches
        case other

        var title: String {
            switch self {
            case .app: "App 本體"
            case .data: "單字與進度"
            case .documents: "PDF 講義"
            case .caches: "快取"
            case .other: "其他"
            }
        }

        var color: Color {
            switch self {
            case .app: Color.er.primary
            case .data: Color.er.info
            case .documents: Color.er.accent
            case .caches: Color.er.ratingHard
            case .other: Color.er.outlineStrong
            }
        }
    }

    struct Slice: Identifiable, Equatable, Sendable {
        let kind: Kind
        let bytes: Int64
        var id: Kind { kind }
    }

    /// 照固定順序，0 位元組的不列
    let slices: [Slice]

    var total: Int64 { slices.reduce(0) { $0 + $1.bytes } }

    func bytes(of kind: Kind) -> Int64 {
        slices.first { $0.kind == kind }?.bytes ?? 0
    }

    /// 走過 App 本體和自己的資料夾算大小（在背景跑）
    static func measure() -> StorageUsage {
        let fm = FileManager.default
        let library = URL.libraryDirectory
        let support = URL.applicationSupportDirectory
        let caches = URL.cachesDirectory

        let app = size(of: Bundle.main.bundleURL)
        // 資料庫本體和 -wal、-shm（AppDatabase.swift）
        let storeFiles = (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
        let data = storeFiles
            .filter { $0.lastPathComponent.hasPrefix("EnRecall.store") }
            .reduce(Int64(0)) { $0 + size(of: $1) }
        let documents = size(of: .documentsDirectory)
        let cache = size(of: caches) + size(of: fm.temporaryDirectory)
        // Library 裡其他東西（設定、收件匣暫存、舊的資料庫……）
        let other = max(0, size(of: library) - size(of: caches) - data)

        let bytes: [Kind: Int64] = [.app: app, .data: data, .documents: documents, .caches: cache, .other: other]
        return StorageUsage(slices: Kind.allCases.compactMap { kind in
            guard let value = bytes[kind], value > 0 else { return nil }
            return Slice(kind: kind, bytes: value)
        })
    }

    /// 清掉 Caches 和 tmp 裡的東西（資料夾本身留著）
    static func clearCaches() {
        let fm = FileManager.default
        for folder in [URL.cachesDirectory, fm.temporaryDirectory] {
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                try? fm.removeItem(at: item)
            }
        }
    }

    /// 檔案或資料夾實際佔用的空間
    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        guard values.isDirectory == true else { return fileSize(values) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                              options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isDirectory != true else { continue }
            total += fileSize(values)
        }
        return total
    }

    private static func fileSize(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
}

// MARK: - 畫面

/// 分段長條：每段照比例，中間留一點縫；很小的段至少看得到一點
private struct StorageBar: View {
    let slices: [StorageUsage.Slice]

    var body: some View {
        let total = max(slices.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let available = max(proxy.size.width - gap * CGFloat(max(slices.count - 1, 0)), 0)
            HStack(spacing: gap) {
                ForEach(slices) { slice in
                    Rectangle()
                        .fill(slice.kind.color)
                        .frame(width: max(available * CGFloat(Double(slice.bytes) / Double(total)), 4))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slices.map { "\($0.kind.title) \($0.bytes.formatted(.byteCount(style: .file)))" }
            .joined(separator: "，"))
    }
}

private struct StorageLegend: View {
    let slice: StorageUsage.Slice

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(slice.kind.color)
                .frame(width: 9, height: 9)
            Text(slice.kind.title)
                .foregroundStyle(Color.er.text)
            Text(slice.bytes, format: .byteCount(style: .file))
                .monospacedDigit()
                .foregroundStyle(Color.er.textSecondary)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// 一行放不下就換行的排版（圖例用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

#Preview("淺色") {
    NavigationStack {
        Form { StorageSection() }
            .scrollContentBackground(.hidden)
            .erPageBackground()
    }
    .previewEnvironment()
}

#Preview("深色") {
    NavigationStack {
        Form { StorageSection() }
            .scrollContentBackground(.hidden)
            .erPageBackground()
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
