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

    public enum ImageSize: Sendable {
        case poster, posterLarge, backdrop, still, profile, logo, original

        var path: String {
            switch self {
            case .poster: "w500"
            case .posterLarge: "w780"
            case .backdrop: "w1280"
            case .still: "w300"
            case .profile: "w185"
            case .logo: "w500"
            case .original: "original"
            }
        }
    }

    public static func imageURL(_ path: String?, size: ImageSize) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBase + size.path + path)
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

public struct TMDBCrewMember: Codable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var job: String?
    public var profilePath: String?
}

public struct TMDBCredits: Codable, Sendable, Hashable {
    public var cast: [TMDBCastMember]
    public var crew: [TMDBCrewMember]?

    /// 導演（放在演員表最前面，角色寫「導演」）
    public var directors: [TMDBCastMember] {
        (crew ?? []).filter { $0.job == "Director" }.map {
            TMDBCastMember(id: $0.id, name: $0.name, character: "導演", profilePath: $0.profilePath, order: -1)
        }
    }
}

public struct TMDBCountry: Codable, Sendable, Hashable {
    public var iso31661: String
    public var name: String?
}

/// 片名 logo、海報、背景圖（append_to_response=images）
public struct TMDBImage: Codable, Sendable, Hashable {
    public var filePath: String
    public var iso6391: String?
    public var iso31661: String?
    public var voteAverage: Double?
    public var width: Int?
    public var height: Int?
}

public struct TMDBImages: Codable, Sendable, Hashable {
    public var logos: [TMDBImage]?
    public var posters: [TMDBImage]?

    public init(logos: [TMDBImage]? = nil, posters: [TMDBImage]? = nil) {
        self.logos = logos
        self.posters = posters
    }

    /// 沒有文字的海報（TMDB 的語言是 null 或「xx」），疊片名 logo 才不會跟海報上的字重疊。挑評分高的
    public func textlessPoster() -> String? {
        (posters ?? [])
            .filter { image in
                let lang = image.iso6391?.lowercased() ?? ""
                return lang.isEmpty || lang == "xx"
            }
            .max { ($0.voteAverage ?? 0) < ($1.voteAverage ?? 0) }?
            .filePath
    }

    /// 片名 logo：繁中（台灣、香港）→ 中文 → 英文 → 原文 → 沒有文字的。同語言挑評分高的
    public func bestLogo(originalLanguage: String?) -> String? {
        func rank(_ image: TMDBImage) -> Int {
            let lang = image.iso6391?.lowercased()
            let region = image.iso31661?.uppercased()
            switch lang {
            case "zh" where region == "TW": return 0
            case "zh" where region == "HK" || region == "MO": return 1
            case "zh" where region == nil: return 2
            case "en": return 3
            case let l? where l == originalLanguage?.lowercased(): return 4
            case "zh": return 5
            case nil: return 6
            default: return 7
            }
        }
        let best = (logos ?? []).min { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return (a.voteAverage ?? 0) > (b.voteAverage ?? 0)
        }
        guard let path = best?.filePath else { return nil }
        // SVG 的 logo 要 PNG 版（UIImage 讀不了 SVG）；TMDB 換副檔名就會給 PNG
        if path.lowercased().hasSuffix(".svg") { return String(path.dropLast(4)) + ".png" }
        return path
    }
}

public enum CountryNames {
    /// 「US」→「美國」
    public static func name(_ code: String) -> String {
        Locale(identifier: "zh_Hant_TW").localizedString(forRegionCode: code) ?? code
    }
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
    public var images: TMDBImages?
    public var originalLanguage: String?
    public var originCountry: [String]?
    public var productionCountries: [TMDBCountry]?

    public var year: Int? { TMDB.year(from: releaseDate) }

    /// 出品國家代碼（第一個）
    public var countryCode: String? { originCountry?.first ?? productionCountries?.first?.iso31661 }

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
    public var images: TMDBImages?
    public var originalLanguage: String?
    public var originCountry: [String]?
    public var createdBy: [TMDBCrewMember]?

    public var year: Int? { TMDB.year(from: firstAirDate) }
    public var countryCode: String? { originCountry?.first }

    /// 主創（劇集沒有單一導演）
    public var creators: [TMDBCastMember] {
        (createdBy ?? []).map { TMDBCastMember(id: $0.id, name: $0.name, character: "主創", profilePath: $0.profilePath, order: -1) }
    }

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
