import Core
import Foundation
import SwiftData

/// 媒體庫的根資料夾（使用者在 Drive 勾選的）
@Model
final class LibraryFolder {
    @Attribute(.unique) var folderId: String
    var name: String
    /// 顯示用路徑：「我的雲端硬碟／影片／電影」
    var path: String
    var addedAt: Date
    var lastScanned: Date?

    init(folderId: String, name: String, path: String) {
        self.folderId = folderId
        self.name = name
        self.path = path
        addedAt = .now
    }
}

enum MatchState: String, Codable, Sendable {
    /// 還沒查 TMDB
    case pending
    /// 自動比對成功
    case matched
    /// 比對不到（放進「未辨識」）
    case unmatched
    /// 使用者手動指定
    case manual
}

/// 一個影片檔：電影，或劇集的一集（Episode 就是 kind == .episode 的 MediaItem，掛在 Show 底下）
@Model
final class MediaItem {
    @Attribute(.unique) var fileId: String
    var fileName: String
    /// 所屬的媒體庫根資料夾
    var libraryFolderId: String
    /// 上層資料夾名稱（由近到遠），解析劇名用
    var parentFolders: [String]
    var size: Int64
    var modifiedTime: Date?
    var addedAt: Date

    // 檔名解析結果
    var kindRaw: String
    var parsedTitle: String
    var parsedYear: Int?
    var season: Int?
    var episode: Int?
    var episodeEnd: Int?

    // TMDB
    var matchStateRaw: String
    var tmdbId: Int?
    var title: String
    var year: Int?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var rating: Double?
    var genres: [String]
    var certification: String?
    /// 演員（JSON 編碼的 [TMDBCastMember]）
    var castData: Data?
    /// 劇集：TMDB 的單集標題與劇照
    var episodeTitle: String?
    var stillPath: String?

    // 規格
    /// 秒（Drive 的 videoMediaMetadata 或 AVAsset）
    var duration: Double
    var width: Int?
    var height: Int?
    /// 檔名標籤（QualityTag.rawValue）
    var fileTags: [String]
    /// 用 AVAsset 讀過 track 之後才有值
    var specProbed: Bool
    var isHDR: Bool
    var isDolbyVision: Bool
    var audioFormat: String?

    // 使用者
    var isFavorite: Bool
    var isWatchlisted: Bool

    var show: Show?

    init(file: DriveFile, libraryFolderId: String, parentFolders: [String]) {
        fileId = file.id
        fileName = file.name
        self.libraryFolderId = libraryFolderId
        self.parentFolders = parentFolders
        size = file.byteCount ?? 0
        modifiedTime = file.modifiedDate
        addedAt = file.createdTime.flatMap(DriveDate.parse) ?? .now
        let parsed = FilenameParser.parse(file.name, parentFolders: parentFolders)
        kindRaw = parsed.kind.rawValue
        parsedTitle = parsed.title
        parsedYear = parsed.year
        season = parsed.season
        episode = parsed.episode
        episodeEnd = parsed.episodeEnd
        matchStateRaw = MatchState.pending.rawValue
        title = parsed.title.isEmpty ? file.name : parsed.title
        year = parsed.year
        genres = []
        duration = file.videoMediaMetadata?.durationSeconds ?? 0
        width = file.videoMediaMetadata?.width
        height = file.videoMediaMetadata?.height
        fileTags = parsed.tags.map(\.rawValue)
        specProbed = false
        isHDR = false
        isDolbyVision = false
        isFavorite = false
        isWatchlisted = false
    }

    var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .movie }
        set { kindRaw = newValue.rawValue }
    }

    var matchState: MatchState {
        get { MatchState(rawValue: matchStateRaw) ?? .pending }
        set { matchStateRaw = newValue.rawValue }
    }

    var cast: [TMDBCastMember] {
        get { castData.flatMap { try? JSONDecoder().decode([TMDBCastMember].self, from: $0) } ?? [] }
        set { castData = try? JSONEncoder().encode(newValue) }
    }

    /// 「S1E05」「S1E01–E02」
    var episodeLabel: String? {
        guard kind == .episode, let episode else { return nil }
        let s = season ?? 1
        if let end = episodeEnd { return "S\(s)E\(episode)–E\(end)" }
        return "S\(s)E\(episode)"
    }
}

/// 劇集（劇 → 季 → 集）
@Model
final class Show {
    /// EpisodeGrouping.key(for: 劇名)
    @Attribute(.unique) var key: String
    var parsedTitle: String
    var parsedYear: Int?
    var matchStateRaw: String
    var tmdbId: Int?
    var title: String
    var year: Int?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var rating: Double?
    var genres: [String]
    var certification: String?
    var castData: Data?
    /// 一集的長度（分），TMDB episode_run_time
    var episodeRuntime: Int?
    var addedAt: Date
    var isFavorite: Bool
    var isWatchlisted: Bool

    @Relationship(deleteRule: .nullify, inverse: \MediaItem.show)
    var episodes: [MediaItem] = []

    init(key: String, title: String, year: Int?) {
        self.key = key
        parsedTitle = title
        parsedYear = year
        matchStateRaw = MatchState.pending.rawValue
        self.title = title
        self.year = year
        genres = []
        addedAt = .now
        isFavorite = false
        isWatchlisted = false
    }

    var matchState: MatchState {
        get { MatchState(rawValue: matchStateRaw) ?? .pending }
        set { matchStateRaw = newValue.rawValue }
    }

    var cast: [TMDBCastMember] {
        get { castData.flatMap { try? JSONDecoder().decode([TMDBCastMember].self, from: $0) } ?? [] }
        set { castData = try? JSONEncoder().encode(newValue) }
    }

    /// 有哪些季（特別篇第 0 季排最後）
    var seasonNumbers: [Int] {
        let all = Set(episodes.map { $0.season ?? 1 })
        return all.sorted { a, b in
            if a == 0 { return false }
            if b == 0 { return true }
            return a < b
        }
    }

    func episodes(inSeason season: Int) -> [MediaItem] {
        episodes.filter { ($0.season ?? 1) == season }
            .sorted { ($0.episode ?? 0, $0.fileName) < ($1.episode ?? 0, $1.fileName) }
    }

    /// 依播出順序排的全部集數（不含特別篇）
    var orderedEpisodes: [MediaItem] {
        seasonNumbers.filter { $0 != 0 }.flatMap { episodes(inSeason: $0) }
    }
}

/// 播放進度
@Model
final class PlaybackState {
    @Attribute(.unique) var fileId: String
    var position: Double
    var duration: Double
    var watched: Bool
    var lastPlayed: Date

    init(fileId: String) {
        self.fileId = fileId
        position = 0
        duration = 0
        watched = false
        lastPlayed = .now
    }

    var progress: Double { PlaybackRules.progress(position: position, duration: duration) }

    var resumePosition: Double? {
        PlaybackRules.resumePosition(position: position, duration: duration, watched: watched)
    }
}
