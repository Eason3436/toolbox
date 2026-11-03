import SwiftData
import SwiftUI

/// 首頁：分類膠囊篩選、依日期分段的兩欄卡片、常駐搜尋列、多選刪除原圖。
struct HomeView: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(QueueStatus.self) private var queueStatus
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @Query(sort: \ScreenshotItem.createdAt, order: .reverse) private var items: [ScreenshotItem]
    @Query(sort: \ScreenshotCollection.createdAt) private var collections: [ScreenshotCollection]

    @State private var category: ScreenshotCategory?
    @State private var dateFilter: DateFilter = .any
    @State private var collectionFilter: PersistentIdentifier?
    @State private var showArchived = false
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var confirmDelete = false

    private let columns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top),
    ]

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.homePath) {
            Group {
                if router.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    browseContent
                } else {
                    SearchResultsView(query: router.searchText, items: filtered(includeArchived: true))
                }
            }
            .navigationTitle(showArchived ? "已封存" : "截圖")
            .navigationSubtitle(queueStatus.progressText ?? countText)
            .searchable(text: $router.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋標題、內容、文字")
            .toolbar { toolbarContent }
            .navigationDestination(for: ScreenshotRoute.self) { route in
                ScreenshotDetailView(assetID: route.assetID)
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting { selectionBar }
            }
            .confirmationDialog("刪除 \(selection.count) 張原圖？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("從相簿刪除", role: .destructive) { deleteSelected() }
            } message: {
                Text("會從「照片」刪除原圖（30 天內可在「最近刪除」復原），並移除分析紀錄。")
            }
        }
    }

    // MARK: - 瀏覽

    @ViewBuilder
    private var browseContent: some View {
        let visible = filtered(includeArchived: false)
        if library.hasSynced && items.isEmpty {
            ContentUnavailableView {
                Label("沒有截圖", systemImage: "camera.viewfinder")
            } description: {
                Text("相簿裡（匯入範圍內）還沒有截圖。可以到「設定」放寬匯入範圍。")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if library.access == .limited { limitedBanner }
                    if queueStatus.readiness != .available { readinessBanner }
                    CategoryCapsules(selection: $category)
                    if visible.isEmpty {
                        ContentUnavailableView("沒有符合的截圖", systemImage: "line.3.horizontal.decrease.circle", description: Text("換個分類或篩選條件看看。"))
                            .padding(.top, 40)
                    } else {
                        grid(for: visible)
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshable { library.sync() }
        }
    }

    private func grid(for visible: [ScreenshotItem]) -> some View {
        let pinned = visible.filter(\.isPinned)
        let rest = visible.filter { !$0.isPinned }
        return LazyVGrid(columns: columns, spacing: 16) {
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { card(for: $0) }
                } header: {
                    sectionHeader("已釘選", symbol: "pin.fill")
                }
            }
            ForEach(DayGrouping.sections(from: rest, date: \.createdAt)) { section in
                Section {
                    ForEach(section.items) { card(for: $0) }
                } header: {
                    sectionHeader(DayGrouping.title(for: section.day), symbol: nil)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func sectionHeader(_ title: String, symbol: String?) -> some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.subheadline) }
            Text(title).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func card(for item: ScreenshotItem) -> some View {
        if isSelecting {
            Button {
                if selection.contains(item.assetID) { selection.remove(item.assetID) } else { selection.insert(item.assetID) }
            } label: {
                ScreenshotCard(item: item)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selection.contains(item.assetID) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selection.contains(item.assetID) ? Color.accentColor : Color.black.opacity(0.3))
                            .padding(8)
                    }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: ScreenshotRoute(assetID: item.assetID)) {
                ScreenshotCard(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu { ItemMenu(item: item) }
        }
    }

    // MARK: - 篩選

    private func filtered(includeArchived: Bool) -> [ScreenshotItem] {
        items.filter { item in
            if !includeArchived && item.isArchived != showArchived { return false }
            if let category, item.category != category.rawValue { return false }
            if !dateFilter.contains(item.createdAt) { return false }
            if let collectionFilter, !item.collections.contains(where: { $0.persistentModelID == collectionFilter }) { return false }
            return true
        }
    }

    private var countText: String {
        items.isEmpty ? "" : "共 \(items.count.formatted()) 張"
    }

    // MARK: - 工具列

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("日期", selection: $dateFilter) {
                    ForEach(DateFilter.allCases) { Text($0.title).tag($0) }
                }
                Picker("收藏集", selection: $collectionFilter) {
                    Text("全部收藏集").tag(PersistentIdentifier?.none)
                    ForEach(collections) { collection in
                        Label(collection.name, systemImage: collection.symbol)
                            .tag(Optional(collection.persistentModelID))
                    }
                }
                Toggle("顯示已封存", isOn: $showArchived)
            } label: {
                Label("篩選", systemImage: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(isSelecting ? "完成" : "選取") {
                isSelecting.toggle()
                selection.removeAll()
            }
        }
    }

    private var isFiltering: Bool {
        dateFilter != .any || collectionFilter != nil || showArchived
    }

    private var selectionBar: some View {
        HStack {
            Text(selection.isEmpty ? "選取截圖" : "已選取 \(selection.count) 張")
                .font(.subheadline)
            Spacer()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("刪除原圖", systemImage: "trash")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func deleteSelected() {
        let ids = Array(selection)
        Task {
            if await library.deleteOriginals(ids: ids) {
                selection.removeAll()
                isSelecting = false
            }
        }
    }

    // MARK: - 提示

    private var limitedBanner: some View {
        Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: "只允許取用部分照片，可能看不到全部截圖。", actionTitle: "改成完整取用") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }

    private var readinessBanner: some View {
        Banner(symbol: "apple.intelligence", tint: .purple, text: queueStatus.readiness.message, actionTitle: nil, action: nil)
    }
}

/// 頂部分類膠囊。
struct CategoryCapsules: View {
    @Binding var selection: ScreenshotCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    capsule(title: "全部", symbol: "square.grid.2x2", selected: selection == nil) { selection = nil }
                    ForEach(ScreenshotCategory.allCases) { category in
                        capsule(title: category.rawValue, symbol: category.symbol, selected: selection == category) {
                            selection = selection == category ? nil : category
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollClipDisabled()
    }

    private func capsule(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .tint(selected ? Color.accentColor : nil)
    }
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.subheadline)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).font(.subheadline.bold())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(in: .rect(cornerRadius: 20))
        .padding(.horizontal, 16)
    }
}

/// 長按選單：釘選、封存、重新分析。
struct ItemMenu: View {
    let item: ScreenshotItem

    var body: some View {
        Button {
            item.isPinned.toggle()
        } label: {
            Label(item.isPinned ? "取消釘選" : "釘選", systemImage: item.isPinned ? "pin.slash" : "pin")
        }
        Button {
            item.isArchived.toggle()
        } label: {
            Label(item.isArchived ? "取消封存" : "封存", systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
        }
        Button {
            let id = item.assetID
            Task { await AppServices.shared.queue.reanalyze(id) }
        } label: {
            Label("重新分析", systemImage: "arrow.clockwise")
        }
    }
}
