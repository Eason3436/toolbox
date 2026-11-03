import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showImporter = false
    @State private var showPacks = false
    @State private var selected: OperationBox?
    @State private var loadingPhotos = false
    @State private var dropTargeted = false
    @State private var showLivePhoto = false

    var body: some View {
        NavigationStack {
            Group {
                if model.files.isEmpty {
                    emptyState
                } else {
                    fileList
                }
            }
            .background(Color.tbGround.ignoresSafeArea())
            .navigationTitle("工具箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            // 照片挑選器用 isPresented 開啟；放在 Menu 裡的 PhotosPicker 常常選了沒反應。
            .photosPicker(isPresented: $showPhotos, selection: $photoItems,
                          matching: .any(of: [.images, .videos]), photoLibrary: .shared())
            .sheet(isPresented: $showImporter) {
                DocumentPicker { urls in
                    showImporter = false
                    Task { @MainActor in model.add(urls: urls) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItems) { _, items in loadPhotos(items) }
            .sheet(item: $selected) { box in
                OperationView(operation: box.op, inputs: model.files.map(\.url))
            }
            .sheet(isPresented: $showPacks) {
                PacksView()
            }
            .sheet(isPresented: $showLivePhoto) {
                LivePhotoView(identifiers: model.livePhotoIDs)
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls: urls)
                return !urls.isEmpty
            } isTargeted: { dropTargeted = $0 }
            .alert("工具箱", isPresented: Binding(get: { model.banner != nil }, set: { if !$0 { model.banner = nil } })) {
                Button("好") { model.banner = nil }
            } message: {
                Text(model.banner ?? "")
            }
            .overlay {
                if loadingPhotos {
                    ProgressView("載入照片中…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .tint(.tbAccent)
    }

    // MARK: 標題

    private var largeTitle: some View {
        Text("工具箱")
            .font(.tbLargeTitle)
            .tracking(1)
            .foregroundStyle(Color.tbInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: 空白首頁

    private var emptyState: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    largeTitle
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

                    Spacer(minLength: 32)

                    VStack(spacing: 32) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(dropTargeted ? Color.tbAccent : Color.tbInkSecondary)
                            .symbolEffect(.bounce, value: dropTargeted)
                            .frame(width: 112, height: 112)
                            .background(Circle().fill(dropTargeted ? Color.tbAccentSoft : Color.tbSurface))
                            .overlay(Circle().strokeBorder(Color.tbHairline, lineWidth: 0.5))
                        VStack(spacing: 8) {
                            Text("還沒有檔案")
                                .font(.tbTitle)
                                .foregroundStyle(Color.tbInk)
                            Text("加入照片、影片、音訊、PDF 或文件，\n就會列出可以做的事。")
                                .font(.subheadline)
                                .foregroundStyle(Color.tbInkSecondary)
                                .multilineTextAlignment(.center)
                        }
                        addMenu {
                            Label("加入檔案", systemImage: "plus")
                                .font(.headline)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .padding(.horizontal, 32)

                    Spacer(minLength: 32)

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            showPacks = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox")
                                    .font(.title3)
                                    .foregroundStyle(Color.tbInkSecondary)
                                    .frame(width: 28)
                                Text("功能包")
                                    .foregroundStyle(Color.tbInk)
                                Spacer()
                                Text(packCountText)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.tbInkSecondary)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.tbInkTertiary)
                            }
                            .padding(.leading, 16)
                            .padding(.trailing, 12)
                            .frame(minHeight: 52)
                            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.tbSurface))
                        }
                        .buttonStyle(.plain)
                        Text("也可以從其他 App 用「分享 › 工具箱」把檔案丟進來。")
                            .font(.footnote)
                            .foregroundStyle(Color.tbInkSecondary)
                            .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .frame(minHeight: proxy.size.height)
            }
        }
    }

    private var packCountText: String {
        _ = model.packsVersion
        let count = PackStore.loadAll().count
        return count == 0 ? "" : "\(count) 個已安裝"
    }

    // MARK: 已加入檔案

    private var fileList: some View {
        let operations = availableOperations
        let liveCount = model.livePhotoIDs.count
        return List {
            Section {
                largeTitle
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }

            Section {
                ForEach(model.files) { file in
                    FileRow(file: file) {
                        if let index = model.files.firstIndex(of: file) {
                            withAnimation { model.remove(at: IndexSet(integer: index)) }
                        }
                    }
                    .listRowBackground(Color.tbSurface)
                }
                .onDelete { model.remove(at: $0) }
                .onMove { model.move(from: $0, to: $1) }
            } header: {
                Text(summaryTitle)
                    .monospacedDigit()
                    .foregroundStyle(Color.tbInkSecondary)
            }

            Section {
                if liveCount > 0 {
                    Button {
                        showLivePhoto = true
                    } label: {
                        ActionRowLabel(title: "原況照片瘦身",
                                       subtitle: "\(liveCount) 張原況照片，移除影片部分，保留編輯與人像",
                                       systemImage: "livephoto")
                    }
                    .listRowBackground(Color.tbSurface)
                }
                if operations.isEmpty && liveCount == 0 {
                    Text("這些檔案沒有共通的動作。試著只留下同一種類型的檔案。")
                        .font(.subheadline)
                        .foregroundStyle(Color.tbInkSecondary)
                        .listRowBackground(Color.tbSurface)
                } else {
                    ForEach(operations) { box in
                        Button {
                            selected = box
                        } label: {
                            ActionRowLabel(title: box.op.title, subtitle: box.op.subtitle,
                                           systemImage: box.op.systemImage)
                        }
                        .listRowBackground(Color.tbSurface)
                    }
                }
            } header: {
                Text("可以做的事")
                    .foregroundStyle(Color.tbInkSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(24)
        .tbGroundBackground()
    }

    private var availableOperations: [OperationBox] {
        _ = model.packsVersion
        return Registry.available(for: model.kinds).map { OperationBox(op: $0) }
    }

    private var summaryTitle: String {
        let kinds = Set(model.kinds)
        let label = kinds.count == 1 ? (kinds.first?.label ?? "檔案") : "檔案"
        let total = model.files.reduce(Int64(0)) { $0 + $1.size }
        return "\(model.files.count) 個\(label) · \(Workspace.formattedSize(total))"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Color.clear.frame(width: 1, height: 1)
        }
        if !model.files.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button("清除", role: .destructive) { withAnimation { model.clear() } }
                    .tint(.tbDanger)
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                addSources
                Divider()
                Button {
                    showPacks = true
                } label: {
                    Label("功能包", systemImage: "shippingbox")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    /// 唯一的加入入口：相簿和「檔案」放在同一個選單。
    private func addMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            addSources
        } label: {
            label()
        }
        .menuStyle(.button)
    }

    @ViewBuilder
    private var addSources: some View {
        Button {
            showPhotos = true
        } label: {
            Label("照片圖庫", systemImage: "photo.on.rectangle")
        }
        Button {
            showImporter = true
        } label: {
            Label("檔案", systemImage: "folder")
        }
    }

    // MARK: 載入照片

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        loadingPhotos = true
        Task {
            var picked: [(url: URL, assetID: String?, isLive: Bool)] = []
            var failures: [String] = []
            for item in items {
                let types = item.supportedContentTypes
                let isLive = types.contains { $0.conforms(to: .livePhoto) }
                let isMovie = !isLive && types.contains { $0.conforms(to: .movie) }
                do {
                    let url = try await Self.load(item, isMovie: isMovie)
                    picked.append((url, item.itemIdentifier, isLive))
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            model.addPhotos(picked)
            if !failures.isEmpty {
                model.banner = "有 \(failures.count) 個項目無法載入：\(failures.first ?? "")"
            }
            photoItems = []
            loadingPhotos = false
        }
    }

    /// 先用檔案方式拿原檔；拿不到就改拿資料再自己寫成檔案。
    private static func load(_ item: PhotosPickerItem, isMovie: Bool) async throws -> URL {
        if isMovie {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) { return movie.url }
        } else {
            if let image = try? await item.loadTransferable(type: PickedImage.self) { return image.url }
        }
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ToolError("讀不到這個項目（可能還在 iCloud 下載中）")
        }
        let type = item.supportedContentTypes.first { $0.conforms(to: isMovie ? .movie : .image) }
            ?? item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? (isMovie ? "mov" : "jpg")
        let dir = try Workspace.newDirectory("Inputs")
        let name = isMovie ? "影片" : "照片"
        let url = Workspace.uniqueURL(in: dir, base: name, ext: ext)
        try data.write(to: url, options: .atomic)
        return url
    }
}

struct PickedImage: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedImage(url: try Workspace.adopt(received.file))
        }
    }
}

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMovie(url: try Workspace.adopt(received.file))
        }
    }
}
