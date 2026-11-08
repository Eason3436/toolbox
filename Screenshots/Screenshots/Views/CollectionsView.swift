import SwiftData
import SwiftUI

/// 收藏集：格狀顯示，可自訂名稱、圖示與自動規則。
struct CollectionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScreenshotCollection.createdAt) private var collections: [ScreenshotCollection]
    @State private var editing: CollectionDraft?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if collections.isEmpty {
                    ContentUnavailableView {
                        Label("還沒有收藏集", systemImage: "square.grid.2x2")
                    } description: {
                        Text("建立收藏集來整理截圖，也可以設定「分類自動加入」。")
                    } actions: {
                        Button("建立收藏集") { editing = CollectionDraft() }
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(collections) { collection in
                                NavigationLink(value: collection.persistentModelID) {
                                    CollectionTile(collection: collection)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("編輯", systemImage: "pencil") { editing = CollectionDraft(collection) }
                                    Button("刪除收藏集", systemImage: "trash", role: .destructive) {
                                        modelContext.delete(collection)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("收藏集")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新增", systemImage: "plus") { editing = CollectionDraft() }
                }
            }
            .navigationDestination(for: PersistentIdentifier.self) { id in
                if let collection = collections.first(where: { $0.persistentModelID == id }) {
                    CollectionDetailView(collection: collection) { editing = CollectionDraft(collection) }
                }
            }
            .navigationDestination(for: ScreenshotRoute.self) { route in
                ScreenshotDetailView(assetID: route.assetID)
            }
            .sheet(item: $editing) { draft in
                CollectionEditor(draft: draft)
            }
        }
    }
}

struct CollectionTile: View {
    let collection: ScreenshotCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let first = collection.items.sorted(by: { $0.createdAt > $1.createdAt }).first {
                    AssetThumbnail(assetID: first.assetID)
                        .overlay(Color.black.opacity(0.15))
                } else {
                    Rectangle().fill(.quaternary)
                }
                Image(systemName: collection.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(16)
                    .glassEffect(in: .circle)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(collection.items.count) 張")
                    if let rule = collection.autoRuleCategory {
                        Text("・自動：\(rule)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}

struct CollectionDetailView: View {
    let collection: ScreenshotCollection
    let onEdit: () -> Void
    private let columns = [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)]

    var body: some View {
        let items = collection.items.sorted { $0.createdAt > $1.createdAt }
        Group {
            if items.isEmpty {
                ContentUnavailableView("這個收藏集是空的", systemImage: collection.symbol, description: Text("在截圖詳情頁按「⋯ → 加入收藏集」。"))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink(value: ScreenshotRoute(assetID: item.assetID)) {
                                ScreenshotCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(collection.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("編輯", action: onEdit)
            }
        }
    }
}

/// 編輯中的收藏集內容。
struct CollectionDraft: Identifiable {
    let id = UUID()
    var existing: ScreenshotCollection?
    var name = ""
    var symbol = "star"
    var autoRuleCategory: String?

    init() {}

    init(_ collection: ScreenshotCollection) {
        existing = collection
        name = collection.name
        symbol = collection.symbol
        autoRuleCategory = collection.autoRuleCategory
    }
}

struct CollectionEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State var draft: CollectionDraft

    static let symbols = [
        "star", "heart", "bookmark", "tag", "folder", "bag", "cart", "fork.knife", "cup.and.saucer",
        "airplane", "car", "house", "building.2", "ticket", "creditcard", "book", "graduationcap",
        "lightbulb", "briefcase", "gift", "gamecontroller", "music.note", "film", "camera",
        "person.2", "pawprint", "leaf", "sparkles", "flag", "mappin.and.ellipse",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField("例如：想去的餐廳", text: $draft.name)
                }
                Section("圖示") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button {
                                draft.symbol = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                                    .background(draft.symbol == symbol ? Color.accentColor.opacity(0.25) : .clear, in: .circle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Picker("分類自動加入", selection: $draft.autoRuleCategory) {
                        Text("不自動加入").tag(String?.none)
                        ForEach(ScreenshotCategory.allCases) { category in
                            Label(category.rawValue, systemImage: category.symbol).tag(Optional(category.rawValue))
                        }
                    }
                } footer: {
                    Text("例如選「票券訂單」，分析結果是這個分類的截圖都會自動加入。")
                }
            }
            .navigationTitle(draft.existing == nil ? "新增收藏集" : "編輯收藏集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存", systemImage: "checkmark") { save() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let collection: ScreenshotCollection
        if let existing = draft.existing {
            existing.name = name
            existing.symbol = draft.symbol
            existing.autoRuleCategory = draft.autoRuleCategory
            collection = existing
        } else {
            collection = ScreenshotCollection(name: name, symbol: draft.symbol, autoRuleCategory: draft.autoRuleCategory)
            modelContext.insert(collection)
        }
        // 套用自動規則到已分析的截圖
        if let rule = draft.autoRuleCategory {
            let ruleValue: String? = rule
            let descriptor = FetchDescriptor<ScreenshotItem>(predicate: #Predicate { $0.category == ruleValue })
            for item in (try? modelContext.fetch(descriptor)) ?? [] where !collection.items.contains(where: { $0.assetID == item.assetID }) {
                collection.items.append(item)
            }
        }
        try? modelContext.save()
        dismiss()
    }
}
