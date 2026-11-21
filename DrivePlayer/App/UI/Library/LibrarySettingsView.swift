import SwiftData
import SwiftUI

/// 媒體庫設定：瀏覽 Drive 勾選資料夾、手動重新掃描、顯示掃描進度
struct LibrarySettingsView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \LibraryFolder.addedAt) private var folders: [LibraryFolder]
    @Query private var items: [MediaItem]
    @State private var browsing = false

    private var library: LibraryManager { services.library }

    var body: some View {
        List {
            if let progress = library.progress {
                Section("掃描中") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ProgressView()
                            Text("正在掃描「\(progress.folderName)」")
                        }
                        Text("已讀 \(progress.foldersScanned) 個資料夾，找到 \(progress.videosFound) 部影片")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(progress.current)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Button("停止掃描", role: .destructive) { library.cancelScan() }
                }
            }
            if let error = library.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            Section {
                ForEach(folders) { folder in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(folder.name, systemImage: "folder.fill")
                        Text(folder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("\(count(in: folder)) 部影片")
                            if let date = folder.lastScanned {
                                Text("・上次掃描 \(date.formatted(.relative(presentation: .named)))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("移除", role: .destructive) { library.removeFolder(folder) }
                    }
                }
                Button {
                    browsing = true
                } label: {
                    Label("加入資料夾", systemImage: "plus")
                }
                .disabled(services.auth.state != .signedIn)
            } header: {
                Text("媒體庫資料夾")
            } footer: {
                if services.auth.state != .signedIn {
                    Text("先登入 Google 才能加入資料夾")
                } else if folders.isEmpty {
                    Text("選一個放電影或劇集的資料夾，子資料夾也會一起掃描。")
                } else {
                    Text("往左滑可以移除資料夾（不會刪除雲端硬碟上的檔案）。")
                }
            }

            if !folders.isEmpty {
                Section {
                    Button {
                        library.scanAll()
                    } label: {
                        Label("重新掃描全部", systemImage: "arrow.clockwise")
                    }
                    .disabled(library.isScanning || services.auth.state != .signedIn)
                }
            }
        }
        .navigationTitle("媒體庫")
        .sheet(isPresented: $browsing) {
            NavigationStack {
                DriveBrowserView(folder: .root, onAddFolder: add)
                    .navigationDestination(for: DriveFolderRef.self) { folder in
                        DriveBrowserView(folder: folder, onAddFolder: add)
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { browsing = false }
                        }
                    }
            }
        }
    }

    private func add(_ folder: DriveFolderRef) {
        library.addFolder(folder)
        browsing = false
    }

    private func count(in folder: LibraryFolder) -> Int {
        items.lazy.filter { $0.libraryFolderId == folder.folderId }.count
    }
}
