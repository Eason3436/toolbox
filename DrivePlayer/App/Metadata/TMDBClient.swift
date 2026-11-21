import Core
import Foundation

enum TMDBError: LocalizedError {
    case notConfigured
    case unauthorized
    case http(Int)
    case offline

    var errorDescription: String? {
        switch self {
        case .notConfigured: "還沒有輸入 TMDB API Key，請到「設定」輸入"
        case .unauthorized: "TMDB API Key 無效"
        case .http(let code): "TMDB 回應錯誤（\(code)）"
        case .offline: "沒有網路連線"
        }
    }
}

/// 同時最多 N 個工作
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { available = count }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// TMDB v3。同時最多 4 個請求。API Key 可以是 v3 key 或 v4 Read Access Token（eyJ… 開頭）。
final class TMDBClient: Sendable {
    static let language = "zh-TW"
    static let fallbackLanguage = "en-US"
    /// 片名 logo 要哪些語言的（null 是沒有文字的圖）
    static let imageLanguages = "zh,en,ja,ko,xx,null"

    private let apiKey: String
    private let session: URLSession
    private let limiter = AsyncSemaphore(4)

    init?(apiKey: String?) {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    func searchMovies(_ query: String, year: Int? = nil, language: String = TMDBClient.language) async throws -> [TMDBMovieSummary] {
        var params = ["query": query, "language": language, "include_adult": "false"]
        if let year { params["year"] = String(year) }
        let page: TMDBPage<TMDBMovieSummary> = try await get("/search/movie", params)
        return page.results
    }

    func searchTV(_ query: String, year: Int? = nil, language: String = TMDBClient.language) async throws -> [TMDBTVSummary] {
        var params = ["query": query, "language": language, "include_adult": "false"]
        if let year { params["first_air_date_year"] = String(year) }
        let page: TMDBPage<TMDBTVSummary> = try await get("/search/tv", params)
        return page.results
    }

    /// 確認 key 能用（輸入時檢查）
    func validate() async throws {
        struct Configuration: Decodable, Sendable { var images: Images?; struct Images: Decodable, Sendable { var baseUrl: String? } }
        let _: Configuration = try await get("/configuration", [:])
    }

    func movie(id: Int, language: String = TMDBClient.language) async throws -> TMDBMovieDetails {
        try await get("/movie/\(id)", ["language": language, "append_to_response": "credits,release_dates,images", "include_image_language": Self.imageLanguages])
    }

    func tv(id: Int, language: String = TMDBClient.language) async throws -> TMDBTVDetails {
        try await get("/tv/\(id)", ["language": language, "append_to_response": "credits,content_ratings,images", "include_image_language": Self.imageLanguages])
    }

    func season(tvId: Int, number: Int, language: String = TMDBClient.language) async throws -> TMDBSeasonDetails {
        try await get("/tv/\(tvId)/season/\(number)", ["language": language])
    }

    private func get<T: Decodable & Sendable>(_ path: String, _ params: [String: String]) async throws -> T {
        var c = URLComponents(string: TMDB.apiBase + path)!
        var items = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let isBearer = apiKey.hasPrefix("eyJ")
        if !isBearer { items.append(URLQueryItem(name: "api_key", value: apiKey)) }
        c.queryItems = items
        var request = URLRequest(url: c.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isBearer { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        await limiter.wait()
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            await limiter.signal()
            throw TMDBError.offline
        } catch {
            await limiter.signal()
            throw error
        }
        await limiter.signal()

        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return try TMDB.decoder.decode(T.self, from: result.0)
        case 401: throw TMDBError.unauthorized
        default: throw TMDBError.http(status)
        }
    }
}
