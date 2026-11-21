import Foundation

/// TMDB v3 回應的 Codable 模型。解碼時用 `TMDB.decoder`（snake_case → camelCase）。
public enum TMDB {
    public static let apiBase = "https://api.themoviedb.org/3"
    public static let imageBase = "https://image.tmdb.org/t/p/"

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public enum ImageSize: String, Sendable {
        case poster = "w500"
        case backdrop = "w1280"
        case still = "w300"
        case profile = "w185"
        case original
    }

    public static func imageURL(_ path: String?, size: ImageSize) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBase + size.rawValue + path)
    }

    /// 「2025-03-01」→ 2025
    public static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }
}

public struct TMDBPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public var page: Int
    public var results: [Item]
    public var totalResults: Int?
    public var totalPages: Int?
}

public struct TMDBGenre: Codable, Sendable, Hashable {
    public var id: Int
    public var name: String
}

public struct TMDBMovieSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var originalTitle: String?
    public var releaseDate: String?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var voteAverage: Double?
    public var popularity: Double?

    public var year: Int? { TMDB.year(from: releaseDate) }
}

public struct TMDBTVSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var firstAirDate: String?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var voteAverage: Double?
    public var popularity: Double?

    public var year: Int? { TMDB.year(from: firstAirDate) }
}

public struct TMDBCastMember: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var character: String?
    public var profilePath: String?
    public var order: Int?
}

public struct TMDBCredits: Codable, Sendable, Hashable {
    public var cast: [TMDBCastMember]
}

public struct TMDBReleaseDates: Codable, Sendable, Hashable {
    public struct Country: Codable, Sendable, Hashable {
        public var iso31661: String
        public var releaseDates: [Entry]
    }
    public struct Entry: Codable, Sendable, Hashable {
        public var certification: String?
    }
    public var results: [Country]
}

public struct TMDBContentRatings: Codable, Sendable, Hashable {
    public struct Rating: Codable, Sendable, Hashable {
        public var iso31661: String
        public var rating: String?
    }
    public var results: [Rating]
}

public struct TMDBMovieDetails: Codable, Sendable, Hashable {
    public var id: Int
    public var title: String
    public var originalTitle: String?
    public var overview: String?
    public var releaseDate: String?
    public var runtime: Int?
    public var genres: [TMDBGenre]?
    public var posterPath: String?
    public var backdropPath: String?
    public var voteAverage: Double?
    public var credits: TMDBCredits?
    public var releaseDates: TMDBReleaseDates?

    public var year: Int? { TMDB.year(from: releaseDate) }

    /// 分級：台灣 → 美國 → 任何有填的
    public var certification: String? {
        guard let results = releaseDates?.results else { return nil }
        for code in ["TW", "US"] {
            if let c = results.first(where: { $0.iso31661 == code })?
                .releaseDates.compactMap(\.certification).first(where: { !$0.isEmpty }) {
                return c
            }
        }
        return nil
    }
}

public struct TMDBSeasonSummary: Codable, Sendable, Hashable {
    public var id: Int?
    public var seasonNumber: Int
    public var name: String?
    public var episodeCount: Int?
    public var posterPath: String?
    public var airDate: String?
}

public struct TMDBTVDetails: Codable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var overview: String?
    public var firstAirDate: String?
    public var episodeRunTime: [Int]?
    public var genres: [TMDBGenre]?
    public var posterPath: String?
    public var backdropPath: String?
    public var voteAverage: Double?
    public var numberOfSeasons: Int?
    public var seasons: [TMDBSeasonSummary]?
    public var credits: TMDBCredits?
    public var contentRatings: TMDBContentRatings?

    public var year: Int? { TMDB.year(from: firstAirDate) }

    public var certification: String? {
        guard let results = contentRatings?.results else { return nil }
        for code in ["TW", "US"] {
            if let r = results.first(where: { $0.iso31661 == code })?.rating, !r.isEmpty { return r }
        }
        return nil
    }
}

public struct TMDBEpisode: Codable, Sendable, Hashable {
    public var id: Int?
    public var episodeNumber: Int
    public var seasonNumber: Int?
    public var name: String?
    public var overview: String?
    public var stillPath: String?
    public var runtime: Int?
    public var airDate: String?
    public var voteAverage: Double?
}

public struct TMDBSeasonDetails: Codable, Sendable, Hashable {
    public var id: Int?
    public var seasonNumber: Int
    public var name: String?
    public var overview: String?
    public var posterPath: String?
    public var episodes: [TMDBEpisode]
}
