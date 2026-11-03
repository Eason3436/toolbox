import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var photoItems: [PhotosPickerItem] = []
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
            .navigationTitle("工具箱")
            .toolbar { toolbar }
            .sheet(isPresented: $showImporter) {
                DocumentPicker { urls in
                    // 先關掉挑選器再加入，避免和其他畫面的出現時機打架。
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
    }

    // MARK: 空白首頁

    private var emptyState: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
                        .symbolEffect(.bounce, value: dropTargeted)
                    Text("還沒有檔案")
                        .font(.title2.bold())
                    Text("照片、影片、音訊、PDF 都可以，從相簿或「檔案」加入。\n加入後會自動辨識，列出可以做的事。原況照片也會出現「瘦身」選項。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    addMenu {
                        Label("加入檔案", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Section {
                Button {
                    showPacks = true
                } label: {
                    Label("功能包", systemImage: "puzzlepiece.extension")
                }
            } footer: {
                Text("也可以從其他 App 用「分享 › 工具箱」直接把檔案丟進來。")
            }
        }
    }

    // MARK: 已加入檔案

    private var fileList: some View {
        let operations = availableOperations
        return List {
            Section {
                ForEach(model.files) { file in
                    FileRow(file: file)
                }
                .onDelete { model.remove(at: $0) }
                .onMove { model.move(from: $0, to: $1) }
            } header: {
                Text(summaryTitle)
            }

            Section("可以做的事") {
                let liveCount = model.livePhotoIDs.count
                if liveCount > 0 {
                    Button {
                        showLivePhoto = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("原況照片瘦身")
                                    .foregroundStyle(.primary)
                                Text("\(liveCount) 張原況照片：移除影片部分，保留照片、編輯與人像資料")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "livephoto.slash")
                        }
                    }
                }
                if operations.isEmpty && liveCount == 0 {
                    Text("這些檔案沒有共通的動作。試著只留下同一種類型的檔案。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(operations) { box in
                        Button {
                            selected = box
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(box.op.title)
                                        .foregroundStyle(.primary)
                                    if !box.op.subtitle.isEmpty {
                                        Text(box.op.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: box.op.systemImage)
                            }
                        }
                    }
                }
            }
        }
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
        if !model.files.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button("清除", role: .destructive) { model.clear() }
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
                    Label("功能包", systemImage: "puzzlepiece.extension")
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
        PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos, .livePhotos]),
                     photoLibrary: .shared()) {
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
            var failed = 0
            for item in items {
                let types = item.supportedContentTypes
                let isLive = types.contains { $0.conforms(to: .livePhoto) }
                let isMovie = !isLive && types.contains { $0.conforms(to: .movie) }
                if isMovie {
                    if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                        picked.append((movie.url, item.itemIdentifier, false))
                    } else { failed += 1 }
                } else {
                    if let image = try? await item.loadTransferable(type: PickedImage.self) {
                        picked.append((image.url, item.itemIdentifier, isLive))
                    } else { failed += 1 }
                }
            }
            model.addPhotos(picked)
            if failed > 0 { model.banner = "有 \(failed) 個項目無法載入（可能還在 iCloud 下載中）" }
            photoItems = []
            loadingPhotos = false
        }
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
