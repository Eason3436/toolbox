import Core
import Foundation
import SwiftUI

/// 首頁、分類用的一筆：一部電影或一部劇
struct LibraryEntry: Identifiable {
    let id: String
    let route: Route
    let posterURL: URL?
    let hero: HeroPoster
    let logoURL: URL?
    let title: String
    let subtitle: String?
    let rating: Double?
    let year: Int?
    let releaseDate: String?
    let countryCode: String?
    let genres: [String]
    let certification: String?
    let overview: String?
    let addedAt: Date

    init(movie m: MediaItem) {
        id = "m-" + m.fileId
        route = .movie(m.fileId)
        posterURL = m.posterURL
        hero = m.heroPoster
        logoURL = TMDB.imageURL(m.logoPath, size: .logo)
        title = m.title
        subtitle = m.year.map(String.init)
        rating = m.rating
        year = m.year
        releaseDate = m.releaseDate
        countryCode = m.countryCode
        genres = m.genres
        certification = m.certification
        overview = m.overview
        addedAt = m.addedAt
    }

    init(show s: Show) {
        id = "s-" + s.key
        route = .show(s.key)
        posterURL = s.posterURL
        hero = s.heroPoster
        logoURL = TMDB.imageURL(s.logoPath, size: .logo)
        title = s.title
        subtitle = "\(s.episodes.count) 集"
        rating = s.rating
        year = s.year
        releaseDate = s.releaseDate
        countryCode = s.countryCode
        genres = s.genres
        certification = s.certification
        overview = s.overview
        // 劇用最新一集的加入時間
        addedAt = s.episodes.map(\.addedAt).max() ?? s.addedAt
    }

    /// 媒體庫裡的電影與劇（不含未辨識、不需要配對的）
    static func library(items: [MediaItem], shows: [Show]) -> [LibraryEntry] {
        items.filter { $0.kind == .movie && $0.matchState.isInLibrary }.map(LibraryEntry.init(movie:))
            + shows.filter { $0.matchState.isInLibrary }.map(LibraryEntry.init(show:))
    }

    /// 選了「不需要配對」的影片與劇
    static func others(items: [MediaItem], shows: [Show]) -> [LibraryEntry] {
        (items.filter { $0.kind == .movie && $0.matchState == .ignored }.map(LibraryEntry.init(movie:))
            + shows.filter { $0.matchState == .ignored }.map(LibraryEntry.init(show:)))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func values(_ kind: CategoryKind) -> [String] {
        LibraryCategory.values(kind, genres: genres, rating: rating, year: year, certification: certification)
    }
}

/// 一個分類（「動畫」「8 分」「2020 年代」）跟裡面的片
struct CategoryGroup: Identifiable {
    let kind: CategoryKind
    let value: String
    let entries: [LibraryEntry]

    var id: String { kind.rawValue + "/" + value }
    var name: String { LibraryCategory.name(kind, value) }

    static func groups(_ kind: CategoryKind, in entries: [LibraryEntry]) -> [CategoryGroup] {
        var buckets: [String: [LibraryEntry]] = [:]
        for entry in entries {
            for value in entry.values(kind) { buckets[value, default: []].append(entry) }
        }
        let order = LibraryCategory.sorted(kind, counts: buckets.mapValues(\.count))
        return order.map { value in
            let list = (buckets[value] ?? []).sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
            return CategoryGroup(kind: kind, value: value, entries: list)
        }
    }
}

/// 首頁輪播：每次打開 App 換一批，有無字海報、片名 logo 的優先
enum FeaturedPicker {
    static func pick(from entries: [LibraryEntry], limit: Int = 6) -> [LibraryEntry] {
        let candidates = entries.filter { $0.hero.url != nil }
        // 同一次打開 App 期間順序固定（Hasher 每次啟動換種子）
        let shuffled = candidates.sorted { $0.id.hashValue < $1.id.hashValue }
        let best = shuffled.filter { $0.hero.textless != nil && $0.logoURL != nil }
        let rest = shuffled.filter { !($0.hero.textless != nil && $0.logoURL != nil) }
        return Array((best + rest).prefix(limit))
    }
}
