import Core
import Foundation
import Observation
import SwiftData

/// 媒體庫：加入／移除 Drive 資料夾、掃描、寫進 SwiftData。
@MainActor
@Observable
final class LibraryManager {
    struct ScanProgress: Equatable {
        var folderName: String
        var foldersScanned: Int
        var videosFound: Int
        var current: String
    }

    private(set) var progress: ScanProgress?
    private(set) var lastError: String?
    var isScanning: Bool { progress != nil }

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored private let drive: DriveClient
    /// 掃描完呼叫（TMDB 比對）
    @ObservationIgnored var onScanFinished: (() -> Void)?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(context: ModelContext, drive: DriveClient) {
        self.context = context
        self.drive = drive
    }

    // MARK: - 資料夾

    func addFolder(_ ref: DriveFolderRef) {
        let id = ref.id
        let existing = try? context.fetch(FetchDescriptor<LibraryFolder>(predicate: #Predicate { $0.folderId == id }))
        if existing?.isEmpty == false {
            scan(onlyFolderId: id)
            return
        }
        let path = (ref.ancestors + [ref.name]).joined(separator: "／")
        context.insert(LibraryFolder(folderId: ref.id, name: ref.name, path: path))
        try? context.save()
        scan(onlyFolderId: ref.id)
    }

    func removeFolder(_ folder: LibraryFolder) {
        let id = folder.folderId
        if let items = try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.libraryFolderId == id })) {
            for item in items { context.delete(item) }
        }
        context.delete(folder)
        try? context.save()
        removeEmptyShows()
        try? context.save()
    }

    // MARK: - 掃描

    func scanAll() {
        scan(onlyFolderId: nil)
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func scan(onlyFolderId: String?) {
        guard scanTask == nil else { return }
        let folders = ((try? context.fetch(FetchDescriptor<LibraryFolder>())) ?? [])
            .filter { onlyFolderId == nil || $0.folderId == onlyFolderId }
            .map { (id: $0.folderId, name: $0.name) }
        guard !folders.isEmpty else { return }
        lastError = nil
        scanTask = Task {
            defer {
                scanTask = nil
                progress = nil
            }
            let scanner = DriveScanner(drive: drive)
            for folder in folders {
                progress = ScanProgress(folderName: folder.name, foldersScanned: 0, videosFound: 0, current: folder.name)
                do {
                    let files = try await scanner.scan(rootId: folder.id, rootName: folder.name) { [weak self] done, videos, current in
                        await self?.updateProgress(folder: folder.name, done: done, videos: videos, current: current)
                    }
                    apply(files, toFolder: folder.id)
                } catch is CancellationError {
                    return
                } catch {
                    lastError = "掃描「\(folder.name)」失敗：\(DriveError.from(error).localizedDescription)"
                }
            }
            onScanFinished?()
        }
    }

    private func updateProgress(folder: String, done: Int, videos: Int, current: String) {
        progress = ScanProgress(folderName: folder, foldersScanned: done, videosFound: videos, current: current)
    }

    /// 把掃描結果寫進資料庫：新增、更新、刪掉已經不在的
    private func apply(_ files: [ScannedFile], toFolder folderId: String) {
        let existing = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.libraryFolderId == folderId }))) ?? []
        var byId = Dictionary(existing.map { ($0.fileId, $0) }, uniquingKeysWith: { a, _ in a })
        let allIds = Set(((try? context.fetch(FetchDescriptor<MediaItem>())) ?? []).map(\.fileId))

        for scanned in files {
            let f = scanned.file
            if let item = byId.removeValue(forKey: f.id) {
                let renamed = item.fileName != f.name || item.parentFolders != scanned.parentFolders
                item.fileName = f.name
                item.parentFolders = scanned.parentFolders
                item.parentId = f.parents?.first ?? item.parentId
                item.size = f.byteCount ?? item.size
                item.modifiedTime = f.modifiedDate
                if let d = f.videoMediaMetadata?.durationSeconds, item.duration == 0 { item.duration = d }
                if renamed, item.matchState != .manual { reparse(item) }
            } else if !allIds.contains(f.id) {
                // 同一個檔案已經在別的媒體庫資料夾裡就不重複加
                let item = MediaItem(file: f, libraryFolderId: folderId, parentFolders: scanned.parentFolders)
                context.insert(item)
            }
        }
        // 剩下的是 Drive 上已經不在的
        for gone in byId.values { context.delete(gone) }

        assignShows()
        try? context.save()
        removeEmptyShows()
        let fid = folderId
        if let folder = try? context.fetch(FetchDescriptor<LibraryFolder>(predicate: #Predicate { $0.folderId == fid })).first {
            folder.lastScanned = .now
        }
        try? context.save()
    }

    private func reparse(_ item: MediaItem) {
        let parsed = FilenameParser.parse(item.fileName, parentFolders: item.parentFolders)
        item.kind = parsed.kind
        item.parsedTitle = parsed.title
        item.parsedYear = parsed.year
        item.season = parsed.season
        item.episode = parsed.episode
        item.episodeEnd = parsed.episodeEnd
        item.fileTags = parsed.tags.map(\.rawValue)
        item.matchState = .pending
        item.show = nil
    }

    /// 單集掛到對應的劇（用解析出來的劇名分組）
    func assignShows() {
        let episodeRaw = MediaKind.episode.rawValue
        let episodes = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.kindRaw == episodeRaw }))) ?? []
        var shows = Dictionary(((try? context.fetch(FetchDescriptor<Show>())) ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for item in episodes where item.show == nil {
            let key = EpisodeGrouping.key(for: item.parsedTitle)
            guard !key.isEmpty else { continue }
            let show = shows[key] ?? {
                let s = Show(key: key, title: item.parsedTitle, year: item.parsedYear)
                context.insert(s)
                shows[key] = s
                return s
            }()
            if show.parsedYear == nil, let y = item.parsedYear { show.parsedYear = y }
            item.show = show
        }
    }

    private func removeEmptyShows() {
        for show in (try? context.fetch(FetchDescriptor<Show>())) ?? [] where show.episodes.isEmpty {
            context.delete(show)
        }
    }
}
