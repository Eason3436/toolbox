import SwiftData
import SwiftUI

/// 詳情頁：大圖 → 標題、摘要 → 快速動作 → 偵測到的資訊 → OCR 全文。
struct ScreenshotDetailView: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Query private var matches: [ScreenshotItem]
    @Query(sort: \ScreenshotCollection.createdAt) private var collections: [ScreenshotCollection]

    @State private var showViewer = false
    @State private var ocrExpanded = false
    @State private var toast: String?
    @State private var errorMessage: String?
    @State private var eventDraft: EventDraft?
    @State private var confirmDelete = false

    init(assetID: String) {
        _matches = Query(filter: #Predicate<ScreenshotItem> { $0.assetID == assetID })
    }

    var body: some View {
        Group {
            if let item = matches.first {
                content(item)
            } else {
                ContentUnavailableView("找不到這張截圖", systemImage: "photo.badge.exclamationmark", description: Text("它可能已經從相簿刪除。"))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("無法完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $eventDraft) { draft in
            EventEditor(title: draft.title, notes: draft.notes, start: draft.start, duration: draft.duration) {
                eventDraft = nil
            }
            .ignoresSafeArea()
        }
    }

    private func content(_ item: ScreenshotItem) -> some View {
        let entities = item.entities
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { showViewer = true } label: {
                    AssetThumbnail(assetID: item.assetID, pointSize: CGSize(width: 420, height: 560))
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 24))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .padding(10)
                                .glassEffect(in: .circle)
                                .padding(12)
                        }
                }
                .buttonStyle(.plain)

                header(item)
                QuickActions(item: item, entities: entities, onToast: show, onError: { errorMessage = $0 }, onEvent: { eventDraft = $0 })
                if !entities.isEmpty { EntityList(entities: entities, onCopy: copy) }
                ocrSection(item)
            }
            .padding(16)
        }
        .fullScreenCover(isPresented: $showViewer) {
            ZoomableViewer(assetID: item.assetID)
        }
        .toolbar { toolbar(item) }
        .confirmationDialog("刪除原圖？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("從相簿刪除", role: .destructive) {
                let id = item.assetID
                Task {
                    if await library.deleteOriginals(ids: [id]) { dismiss() }
                }
            }
        } message: {
            Text("會從「照片」刪除原圖，並移除分析紀錄。")
        }
    }

    @ViewBuilder
    private func header(_ item: ScreenshotItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let category = item.categoryValue {
                    Label(category.rawValue, systemImage: category.symbol)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.3)), in: .capsule)
                }
                if item.isPinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                if item.isArchived { Image(systemName: "archivebox.fill").foregroundStyle(.secondary) }
                Spacer()
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch item.status {
            case .done:
                Text(item.title ?? "截圖").font(.title2.bold())
                if let summary = item.summary, !summary.isEmpty {
                    Text(summary).foregroundStyle(.secondary)
                }
                if !item.keywords.isEmpty {
                    Text(item.keywords.map { "#\($0)" }.joined(separator: "  "))
                        .font(.footnote)
                        .foregroundStyle(.tint)
                }
            case .pending:
                Label("等待 AI 分析", systemImage: "hourglass").font(.title3.bold())
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Label("分析失敗", systemImage: "exclamationmark.triangle.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.orange)
                    if let message = item.failureMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("重新分析") { reanalyze(item) }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    @ViewBuilder
    private func ocrSection(_ item: ScreenshotItem) -> some View {
        if let text = item.ocrText, !text.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("截圖中的文字").font(.headline)
                    Spacer()
                    Button {
                        copy(text)
                    } label: {
                        Label("複製全部", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(ocrExpanded ? nil : 6)
                Button(ocrExpanded ? "收起" : "展開全部") {
                    withAnimation { ocrExpanded.toggle() }
                }
                .font(.subheadline)
            }
            .padding(16)
            .glassEffect(in: .rect(cornerRadius: 20))
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ item: ScreenshotItem) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ItemMenu(item: item)
                Menu {
                    ForEach(collections) { collection in
                        let isMember = collection.items.contains { $0.assetID == item.assetID }
                        Button {
                            toggle(item, in: collection)
                        } label: {
                            Label(collection.name, systemImage: isMember ? "checkmark" : collection.symbol)
                        }
                    }
                    if collections.isEmpty {
                        Text("還沒有收藏集，請到「收藏集」分頁建立。")
                    }
                } label: {
                    Label("加入收藏集", systemImage: "square.grid.2x2")
                }
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("刪除原圖", systemImage: "trash")
                }
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
        }
    }

    private func toggle(_ item: ScreenshotItem, in collection: ScreenshotCollection) {
        if let index = collection.items.firstIndex(where: { $0.assetID == item.assetID }) {
            collection.items.remove(at: index)
            show("已從「\(collection.name)」移除")
        } else {
            collection.items.append(item)
            show("已加入「\(collection.name)」")
        }
    }

    private func reanalyze(_ item: ScreenshotItem) {
        let id = item.assetID
        Task { await AppServices.shared.queue.reanalyze(id) }
    }

    private func copy(_ text: String) {
        ActionService.copy(text)
        show("已複製")
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { if toast == message { toast = nil } }
        }
    }
}

struct EventDraft: Identifiable {
    let id = UUID()
    var title: String
    var notes: String?
    var start: Date
    var duration: TimeInterval?
}

/// 依偵測到的內容顯示快速動作按鈕。
struct QuickActions: View {
    let item: ScreenshotItem
    let entities: ScreenshotEntities
    let onToast: (String) -> Void
    let onError: (String) -> Void
    let onEvent: (EventDraft) -> Void

    var body: some View {
        let firstDate = entities.dates.first(where: { $0.date != nil })
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if let url = entities.urls.first {
                        action("開啟網址", "safari") { ActionService.open(urlString: url) }
                    }
                    if let phone = entities.phoneNumbers.first {
                        action("撥打電話", "phone") { ActionService.call(phone) }
                    }
                    if let place = entities.places.first {
                        action("在地圖開啟", "map") { ActionService.openInMaps(place) }
                    }
                    if let text = item.ocrText, !text.isEmpty {
                        action("複製文字", "doc.on.doc") {
                            ActionService.copy(text)
                            onToast("已複製")
                        }
                    }
                    action("加入提醒事項", "checklist") { addReminder(due: firstDate?.date) }
                    action("加入行事曆", "calendar.badge.plus") {
                        onEvent(EventDraft(
                            title: item.title ?? "截圖",
                            notes: item.summary,
                            start: firstDate?.date ?? nextHour(),
                            duration: firstDate?.duration
                        ))
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    private func addReminder(due: Date?) {
        let title = item.title ?? "截圖待辦"
        let notes = item.summary
        Task {
            do {
                try await ActionService.addReminder(title: title, notes: notes, due: due)
                onToast("已加入提醒事項")
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func nextHour() -> Date {
        let calendar = Calendar.current
        let now = Date.now
        let hour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        return hour
    }
}

/// 偵測到的資訊列表（點一下複製）。
struct EntityList: View {
    let entities: ScreenshotEntities
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("偵測到的資訊").font(.headline)
            group("日期時間", "calendar", entities.dates.map(\.text))
            group("地點", "mappin.and.ellipse", entities.places)
            group("網址", "link", entities.urls)
            group("電話", "phone", entities.phoneNumbers)
            group("價格", "dollarsign.circle", entities.prices)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 20))
    }

    @ViewBuilder
    private func group(_ title: String, _ symbol: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(values, id: \.self) { value in
                    Button { onCopy(value) } label: {
                        Text(value)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
