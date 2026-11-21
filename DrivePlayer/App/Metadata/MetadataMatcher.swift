import Core
import Foundation
import Observation
import SwiftData

struct MovieMetadata: Sendable {
    var details: TMDBMovieDetails
    var overview: String?
}

struct ShowMetadata: Sendable {
    var details: TMDBTVDetails
    var overview: String?
    var seasons: [Int: TMDBSeasonDetails]
}

/// 媒體庫 ↔ TMDB：片名 + 年份比對，抓海報、背景圖、簡介、演員、評分，存回 SwiftData。
/// 比對不到的放進「未辨識」，可以手動搜尋指定。
@MainActor
@Observable
final class MetadataMatcher {
    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var lastError: String?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored let tmdb: TMDBClient?

    init(context: ModelContext, tmdb: TMDBClient?) {
        self.context = context
        self.tmdb = tmdb
    }

    var isConfigured: Bool { tmdb != nil }

    // MARK: - 自動比對

    private enum Job: Sendable {
        case movie(fileId: String, title: String, year: Int?)
        case show(key: String, title: String, year: Int?, tmdbId: Int?, seasons: [Int])
    }

    private enum JobResult: Sendable {
        case movie(fileId: String, MovieMetadata?)
        case show(key: String, ShowMetadata?)
        case failed(String)
    }

    /// 比對所有還沒查過的電影與劇集（掃描完自動呼叫）
    func matchPending() {
        guard let tmdb, !isRunning else { return }
        let pendingRaw = MatchState.pending.rawValue
        let movieRaw = MediaKind.movie.rawValue
        let movies = (try? context.fetch(FetchDescriptor<MediaItem>(
            predicate: #Predicate { $0.matchStateRaw == pendingRaw && $0.kindRaw == movieRaw }
        ))) ?? []
        let shows = (try? context.fetch(FetchDescriptor<Show>())) ?? []

        var jobs: [Job] = movies.map { .movie(fileId: $0.fileId, title: $0.parsedTitle, year: $0.parsedYear) }
        for show in shows {
            switch show.matchState {
            case .pending:
                jobs.append(.show(key: show.key, title: show.parsedTitle, year: show.parsedYear, tmdbId: nil, seasons: show.seasonNumbers))
            case .matched, .manual:
                // 新加入的集數：補單集標題與劇照
                let missing = show.episodes.filter { $0.matchState == .pending }
                if let id = show.tmdbId, !missing.isEmpty {
                    let seasons = Array(Set(missing.map { $0.season ?? 1 })).sorted()
                    jobs.append(.show(key: show.key, title: show.title, year: show.year, tmdbId: id, seasons: seasons))
                }
            case .unmatched:
                break
            }
        }
        guard !jobs.isEmpty else { return }

        isRunning = true
        done = 0
        total = jobs.count
        lastError = nil
        Task {
            await withTaskGroup(of: JobResult.self) { group in
                for job in jobs {
                    group.addTask { await Self.run(job, tmdb: tmdb) }
                }
                for await result in group {
                    apply(result)
                    done += 1
                    if done % 10 == 0 { try? context.save() }
                }
            }
            try? context.save()
            isRunning = false
        }
    }

    nonisolated private static func run(_ job: Job, tmdb: TMDBClient) async -> JobResult {
        do {
            switch job {
            case let .movie(fileId, title, year):
                return .movie(fileId: fileId, try await resolveMovie(title: title, year: year, tmdb: tmdb))
            case let .show(key, title, year, tmdbId, seasons):
                if let tmdbId {
                    return .show(key: key, try await loadShow(id: tmdbId, seasons: seasons, tmdb: tmdb))
                }
                return .show(key: key, try await resolveShow(title: title, year: year, seasons: seasons, tmdb: tmdb))
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func apply(_ result: JobResult) {
        switch result {
        case let .movie(fileId, meta):
            guard let item = fetchItem(fileId) else { return }
            if let meta { apply(meta, to: item) } else { item.matchState = .unmatched }
        case let .show(key, meta):
            guard let show = fetchShow(key) else { return }
            if let meta {
                apply(meta, to: show, state: show.matchState == .manual ? .manual : .matched)
            } else {
                show.matchState = .unmatched
                for e in show.episodes { e.matchState = .unmatched }
            }
        case .failed(let message):
            // 網路錯誤之類：保持 pending，下次再試
            lastError = message
        }
    }

    // MARK: - 手動指定

    func assignMovie(_ item: MediaItem, tmdbId: Int) async throws {
        guard let tmdb else { throw TMDBError.notConfigured }
        let meta = try await Self.loadMovie(id: tmdbId, tmdb: tmdb)
        apply(meta, to: item)
        item.matchState = .manual
        try? context.save()
    }

    func assignShow(_ show: Show, tmdbId: Int) async throws {
        guard let tmdb else { throw TMDBError.notConfigured }
        let meta = try await Self.loadShow(id: tmdbId, seasons: show.seasonNumbers, tmdb: tmdb)
        apply(meta, to: show, state: .manual)
        try? context.save()
    }

    /// 重新自動比對
    func rematch(_ item: MediaItem) {
        if let show = item.show {
            show.matchState = .pending
            show.tmdbId = nil
        } else {
            item.matchState = .pending
        }
        try? context.save()
        matchPending()
    }

    // MARK: - 寫進資料庫

    private func apply(_ meta: MovieMetadata, to item: MediaItem) {
        let d = meta.details
        item.tmdbId = d.id
        item.title = d.title.isEmpty ? (d.originalTitle ?? item.parsedTitle) : d.title
        item.year = d.year ?? item.parsedYear
        item.overview = meta.overview
        item.posterPath = d.posterPath
        item.backdropPath = d.backdropPath
        item.rating = d.voteAverage
        item.genres = d.genres?.map(\.name) ?? []
        item.certification = d.certification
        item.cast = Array((d.credits?.cast ?? []).prefix(20))
        if item.duration == 0, let runtime = d.runtime { item.duration = Double(runtime * 60) }
        item.matchState = .matched
    }

    private func apply(_ meta: ShowMetadata, to show: Show, state: MatchState) {
        let d = meta.details
        show.tmdbId = d.id
        show.title = d.name.isEmpty ? (d.originalName ?? show.parsedTitle) : d.name
        show.year = d.year ?? show.parsedYear
        show.overview = meta.overview
        show.posterPath = d.posterPath
        show.backdropPath = d.backdropPath
        show.rating = d.voteAverage
        show.genres = d.genres?.map(\.name) ?? []
        show.certification = d.certification
        show.cast = Array((d.credits?.cast ?? []).prefix(20))
        show.episodeRuntime = d.episodeRunTime?.first
        show.matchState = state

        for item in show.episodes {
            item.tmdbId = d.id
            item.title = show.title
            item.year = show.year
            item.genres = show.genres
            item.certification = show.certification
            if item.posterPath == nil { item.posterPath = d.posterPath }
            if item.backdropPath == nil { item.backdropPath = d.backdropPath }
            if let season = meta.seasons[item.season ?? 1],
               let ep = season.episodes.first(where: { $0.episodeNumber == item.episode }) {
                item.episodeTitle = ep.name
                item.overview = ep.overview
                item.stillPath = ep.stillPath
                item.rating = ep.voteAverage
                if item.duration == 0, let runtime = ep.runtime { item.duration = Double(runtime * 60) }
            }
            item.matchState = state
        }
    }

    private func fetchItem(_ fileId: String) -> MediaItem? {
        try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.fileId == fileId })).first
    }

    private func fetchShow(_ key: String) -> Show? {
        try? context.fetch(FetchDescriptor<Show>(predicate: #Predicate { $0.key == key })).first
    }

    // MARK: - TMDB 查詢（不在主執行緒）

    nonisolated static func resolveMovie(title: String, year: Int?, tmdb: TMDBClient) async throws -> MovieMetadata? {
        guard !title.isEmpty else { return nil }
        var results = try await tmdb.searchMovies(title, year: year)
        if results.isEmpty, year != nil { results = try await tmdb.searchMovies(title) }
        let candidates = results.map {
            MatchScoring.Candidate(id: $0.id, title: $0.title, originalTitle: $0.originalTitle, year: $0.year, popularity: $0.popularity ?? 0)
        }
        guard let best = MatchScoring.best(query: title, year: year, candidates: candidates) else { return nil }
        return try await loadMovie(id: best.id, tmdb: tmdb)
    }

    nonisolated static func loadMovie(id: Int, tmdb: TMDBClient) async throws -> MovieMetadata {
        let details = try await tmdb.movie(id: id)
        var overview = details.overview
        if overview?.isEmpty ?? true {
            overview = try? await tmdb.movie(id: id, language: TMDBClient.fallbackLanguage).overview
        }
        return MovieMetadata(details: details, overview: overview)
    }

    nonisolated static func resolveShow(title: String, year: Int?, seasons: [Int], tmdb: TMDBClient) async throws -> ShowMetadata? {
        guard !title.isEmpty else { return nil }
        var results = try await tmdb.searchTV(title, year: year)
        if results.isEmpty, year != nil { results = try await tmdb.searchTV(title) }
        let candidates = results.map {
            MatchScoring.Candidate(id: $0.id, title: $0.name, originalTitle: $0.originalName, year: $0.year, popularity: $0.popularity ?? 0)
        }
        // 劇集的年份常常是那一季的年份，不是首播年份，所以年份只當加分
        guard let best = MatchScoring.best(query: title, year: nil, candidates: candidates)
            ?? MatchScoring.best(query: title, year: year, candidates: candidates) else { return nil }
        return try await loadShow(id: best.id, seasons: seasons, tmdb: tmdb)
    }

    nonisolated static func loadShow(id: Int, seasons: [Int], tmdb: TMDBClient) async throws -> ShowMetadata {
        let details = try await tmdb.tv(id: id)
        var overview = details.overview
        if overview?.isEmpty ?? true {
            overview = try? await tmdb.tv(id: id, language: TMDBClient.fallbackLanguage).overview
        }
        var seasonDetails: [Int: TMDBSeasonDetails] = [:]
        await withTaskGroup(of: (Int, TMDBSeasonDetails?).self) { group in
            for n in seasons {
                group.addTask { (n, try? await tmdb.season(tvId: id, number: n)) }
            }
            for await (n, s) in group {
                if let s { seasonDetails[n] = s }
            }
        }
        return ShowMetadata(details: details, overview: overview, seasons: seasonDetails)
    }
}
