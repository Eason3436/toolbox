import Core
import SwiftUI

struct DriveFolderRef: Hashable, Sendable {
    var id: String
    var name: String
    /// 從媒體庫根目錄往下的資料夾名稱（不含自己）
    var ancestors: [String] = []

    static let root = DriveFolderRef(id: DriveAPI.rootId, name: "我的雲端硬碟")
    static let sharedWithMe = DriveFolderRef(id: DriveAPI.sharedWithMeId, name: "與我共用")
}

/// 瀏覽 Google Drive 資料夾，列出子資料夾與可播放的影片。
struct DriveBrowserView: View {
    @Environment(AppServices.self) private var services
    let folder: DriveFolderRef
    /// 有值時顯示「加入媒體庫」按鈕
    var onAddFolder: ((DriveFolderRef) -> Void)?

    @State private var items: [DriveFile] = []
    @State private var loading = true
    @State private var error: String?

    private var folders: [DriveFile] { items.filter(\.isFolder) }
    private var videos: [DriveFile] { items.filter(\.isPlayableVideo) }
    private var otherCount: Int { items.count - folders.count - videos.count }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("重試") { Task { await load() } }
                }
            }
            if !folders.isEmpty {
                Section("資料夾") {
                    ForEach(folders) { f in
                        NavigationLink(value: DriveFolderRef(id: f.id, name: f.name, ancestors: folder.ancestors + [folder.name])) {
                            Label(f.name, systemImage: "folder.fill")
                        }
                    }
                }
            }
            if !videos.isEmpty {
                Section("影片（\(videos.count)）") {
                    ForEach(videos) { v in
                        Button {
                            Task {
                                await services.player.play(PlaybackRequest(fileId: v.id, fileName: v.name, title: v.name))
                            }
                        } label: {
                            DriveFileRow(file: v)
                        }
                        .tint(.primary)
                    }
                }
            }
            if otherCount > 0 {
                Section {
                    Text("另有 \(otherCount) 個不支援的檔案（第一階段只支援 MP4、M4V、MOV）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if loading && items.isEmpty && error == nil {
                SkeletonRows()
            } else if !loading && error == nil && items.isEmpty {
                ContentUnavailableView("資料夾是空的", systemImage: "folder")
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onAddFolder, folder.id != DriveAPI.sharedWithMeId {
                ToolbarItem(placement: .primaryAction) {
                    Button("加入媒體庫", systemImage: "plus.circle.fill") { onAddFolder(folder) }
                }
            }
        }
        .refreshable { await load() }
        .task(id: folder.id) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await services.drive.list(folderId: folder.id)
            error = nil
        } catch {
            self.error = DriveError.from(error).localizedDescription
        }
    }
}

struct DriveFileRow: View {
    let file: DriveFile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.name)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 8) {
                if let bytes = file.byteCount {
                    Text(bytes.formatted(.byteCount(style: .file)))
                }
                if let meta = file.videoMediaMetadata, let w = meta.width, let h = meta.height {
                    Text("\(w)×\(h)")
                }
                if let seconds = file.videoMediaMetadata?.durationSeconds {
                    Text(Timecode.duration(seconds))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
