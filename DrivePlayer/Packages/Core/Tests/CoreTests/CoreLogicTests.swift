import XCTest
@testable import Core

final class EpisodeGroupingTests: XCTestCase {
    func testGroupsBySeasonAndSorts() {
        let files = [
            ("a", "The.Bear.S01E02.mp4"),
            ("b", "The.Bear.S01E01.mp4"),
            ("c", "the bear S02E01.mp4"),
            ("d", "Severance.S01E01.mp4"),
            ("e", "Movie.2020.mp4"),
            ("f", "The Bear S00E01.mp4"),
        ].map { EpisodeGrouping.Input(fileId: $0.0, parsed: FilenameParser.parse($0.1)) }

        let shows = EpisodeGrouping.group(files)
        XCTAssertEqual(shows.map(\.title), ["Severance", "The Bear"])
        let bear = shows[1]
        XCTAssertEqual(bear.seasons.map(\.number), [1, 2, 0])
        XCTAssertEqual(bear.seasons[0].episodes.map(\.fileId), ["b", "a"])
        XCTAssertEqual(bear.episodeCount, 4)

        XCTAssertEqual(EpisodeGrouping.next(after: "b", in: bear)?.fileId, "a")
        XCTAssertEqual(EpisodeGrouping.next(after: "a", in: bear)?.fileId, "c")
        XCTAssertNil(EpisodeGrouping.next(after: "c", in: bear))
    }

    func testKey() {
        XCTAssertEqual(EpisodeGrouping.key(for: "The.Bear"), EpisodeGrouping.key(for: "the bear"))
        XCTAssertEqual(EpisodeGrouping.key(for: "葬送的芙莉蓮"), "葬送的芙莉蓮")
    }
}

final class MatchScoringTests: XCTestCase {
    func testPrefersTitleAndYear() {
        let candidates = [
            MatchScoring.Candidate(id: 1, title: "Dune", year: 1984, popularity: 30),
            MatchScoring.Candidate(id: 2, title: "Dune", year: 2021, popularity: 90),
            MatchScoring.Candidate(id: 3, title: "Dune: Part Two", year: 2024, popularity: 99),
        ]
        XCTAssertEqual(MatchScoring.best(query: "Dune", year: 1984, candidates: candidates)?.id, 1)
        XCTAssertEqual(MatchScoring.best(query: "Dune", year: 2021, candidates: candidates)?.id, 2)
        XCTAssertEqual(MatchScoring.best(query: "Dune Part Two", year: 2024, candidates: candidates)?.id, 3)
    }

    func testOriginalTitle() {
        let candidates = [MatchScoring.Candidate(id: 7, title: "葬送的芙莉蓮", originalTitle: "葬送のフリーレン", year: 2023)]
        XCTAssertEqual(MatchScoring.best(query: "葬送的芙莉蓮", year: nil, candidates: candidates)?.id, 7)
    }

    func testRejectsPoorMatch() {
        let candidates = [MatchScoring.Candidate(id: 1, title: "Completely Different", year: 2001)]
        XCTAssertNil(MatchScoring.best(query: "Zootopia 2", year: 2025, candidates: candidates))
    }
}

final class TMDBModelTests: XCTestCase {
    func testDecodeSearchAndDetails() throws {
        let search = #"{"page":1,"total_results":1,"total_pages":1,"results":[{"id":1084242,"title":"動物方城市2","original_title":"Zootopia 2","release_date":"2025-11-26","poster_path":"/p.jpg","backdrop_path":"/b.jpg","overview":"","vote_average":7.6,"popularity":200.5}]}"#
        let page = try TMDB.decoder.decode(TMDBPage<TMDBMovieSummary>.self, from: Data(search.utf8))
        XCTAssertEqual(page.results.first?.year, 2025)
        XCTAssertEqual(page.results.first?.originalTitle, "Zootopia 2")

        let details = #"{"id":1,"title":"T","runtime":108,"genres":[{"id":16,"name":"動畫"}],"credits":{"cast":[{"id":5,"name":"A","character":"Judy","profile_path":null,"order":0}]},"release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":""},{"certification":"PG"}]}]}}"#
        let movie = try TMDB.decoder.decode(TMDBMovieDetails.self, from: Data(details.utf8))
        XCTAssertEqual(movie.runtime, 108)
        XCTAssertEqual(movie.credits?.cast.first?.character, "Judy")
        XCTAssertEqual(movie.certification, "PG")

        let tv = #"{"id":2,"name":"The Bear","first_air_date":"2022-06-23","episode_run_time":[30],"seasons":[{"season_number":0,"episode_count":1},{"season_number":1,"episode_count":8}],"content_ratings":{"results":[{"iso_3166_1":"TW","rating":"15+"}]}}"#
        let show = try TMDB.decoder.decode(TMDBTVDetails.self, from: Data(tv.utf8))
        XCTAssertEqual(show.year, 2022)
        XCTAssertEqual(show.seasons?.last?.episodeCount, 8)
        XCTAssertEqual(show.certification, "15+")

        let season = #"{"season_number":1,"episodes":[{"episode_number":1,"name":"System","still_path":"/s.jpg","runtime":31}]}"#
        let s = try TMDB.decoder.decode(TMDBSeasonDetails.self, from: Data(season.utf8))
        XCTAssertEqual(s.episodes.first?.name, "System")
    }

    func testImageURL() {
        XCTAssertEqual(TMDB.imageURL("/a.jpg", size: .poster)?.absoluteString, "https://image.tmdb.org/t/p/w500/a.jpg")
        XCTAssertEqual(TMDB.imageURL("/a.jpg", size: .backdrop)?.absoluteString, "https://image.tmdb.org/t/p/w1280/a.jpg")
        XCTAssertNil(TMDB.imageURL(nil, size: .poster))
    }
}

final class PlaybackRulesTests: XCTestCase {
    func testWatchedAndResume() {
        XCTAssertTrue(PlaybackRules.isWatched(position: 90, duration: 100))
        XCTAssertFalse(PlaybackRules.isWatched(position: 89, duration: 100))
        XCTAssertEqual(PlaybackRules.resumePosition(position: 754, duration: 7200, watched: false), 754)
        XCTAssertNil(PlaybackRules.resumePosition(position: 5, duration: 7200, watched: false))
        XCTAssertNil(PlaybackRules.resumePosition(position: 7000, duration: 7200, watched: false))
        XCTAssertNil(PlaybackRules.resumePosition(position: 754, duration: 7200, watched: true))
    }

    func testTimecode() {
        XCTAssertEqual(Timecode.string(754), "00:12:34")
        XCTAssertEqual(Timecode.string(3723.9), "01:02:03")
        XCTAssertEqual(Timecode.duration(8040), "2 小時 14 分")
        XCTAssertEqual(Timecode.duration(2700), "45 分")
    }
}

final class HTTPMessageTests: XCTestCase {
    func testParseRequest() throws {
        let raw = "GET /stream/1AbC_-x9/movie.mp4 HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nRange: bytes=100-\r\nX-Playback-Session-Id: 1\r\n\r\nextra"
        let (head, length) = try XCTUnwrap(HTTPRequestHead.parse(Data(raw.utf8)))
        XCTAssertEqual(head.method, "GET")
        XCTAssertEqual(head.range, "bytes=100-")
        XCTAssertEqual(length, raw.utf8.count - "extra".utf8.count)
        XCTAssertEqual(StreamRoute.fileId(from: head.target), "1AbC_-x9")
    }

    func testIncompleteRequest() {
        XCTAssertNil(HTTPRequestHead.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
    }

    func testRoute() {
        XCTAssertEqual(StreamRoute.fileId(from: "/stream/abc"), "abc")
        XCTAssertEqual(StreamRoute.fileId(from: "/stream/abc?x=1"), "abc")
        XCTAssertNil(StreamRoute.fileId(from: "/other/abc"))
        XCTAssertNil(StreamRoute.fileId(from: "/stream/../etc"))
        XCTAssertEqual(StreamRoute.path(fileId: "abc", filename: "影片 1.mp4"), "/stream/abc/%E5%BD%B1%E7%89%87%201.mp4")
    }

    func testByteRange() {
        XCTAssertEqual(ByteRange.parse("bytes=0-1"), ByteRange(start: 0, end: 1))
        XCTAssertEqual(ByteRange.parse("bytes=500-"), ByteRange(start: 500, end: nil))
        XCTAssertEqual(ByteRange.parse("bytes=-500"), ByteRange(start: nil, end: 500))
        XCTAssertNil(ByteRange.parse("bytes=5-1"))
        XCTAssertNil(ByteRange.parse("items=0-1"))
        XCTAssertEqual(ByteRange(start: 0, end: 1).headerValue, "bytes=0-1")
    }

    func testForwardingHeaders() {
        let head = HTTPResponseHead.forwarding(status: 206, upstream: [
            "Content-Type": "video/mp4", "Content-Length": "2", "Content-Range": "bytes 0-1/1000",
            "X-Goog-Hash": "secret",
        ])
        let text = String(decoding: head.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        XCTAssertTrue(text.contains("Content-Range: bytes 0-1/1000\r\n"))
        XCTAssertTrue(text.contains("Accept-Ranges: bytes\r\n"))
        XCTAssertFalse(text.contains("X-Goog-Hash"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }
}

final class DriveModelTests: XCTestCase {
    func testDecodeList() throws {
        let json = #"{"nextPageToken":"t2","files":[{"id":"f1","name":"Movies","mimeType":"application/vnd.google-apps.folder"},{"id":"v1","name":"Zootopia.2.2025.2160p.DV.Atmos.mp4","mimeType":"video/mp4","size":"53687091200","modifiedTime":"2025-12-01T10:20:30.123Z","videoMediaMetadata":{"width":3840,"height":2160,"durationMillis":"6480000"}},{"id":"v2","name":"clip.MOV","mimeType":"video/quicktime"},{"id":"v3","name":"show.mkv","mimeType":"video/x-matroska"}]}"#
        let list = try JSONDecoder().decode(DriveFileList.self, from: Data(json.utf8))
        XCTAssertEqual(list.nextPageToken, "t2")
        XCTAssertTrue(list.files[0].isFolder)
        XCTAssertFalse(list.files[0].isPlayableVideo)
        XCTAssertTrue(list.files[1].isPlayableVideo)
        XCTAssertEqual(list.files[1].byteCount, 53_687_091_200)
        XCTAssertEqual(list.files[1].videoMediaMetadata?.durationSeconds, 6480)
        XCTAssertNotNil(list.files[1].modifiedDate)
        XCTAssertTrue(list.files[2].isPlayableVideo)
        XCTAssertFalse(list.files[3].isPlayableVideo, "MKV 是第二階段")
    }

    func testListURL() {
        let url = DriveAPI.listURL(folderId: "abc", pageToken: "p+1").absoluteString
        XCTAssertTrue(url.contains("q=%27abc%27%20in%20parents%20and%20trashed%20%3D%20false") || url.contains("q='abc'%20in%20parents"), url)
        XCTAssertTrue(url.contains("pageToken=p%2B1"), url)
        XCTAssertTrue(DriveAPI.listURL(folderId: DriveAPI.sharedWithMeId).absoluteString.contains("sharedWithMe"))
        XCTAssertEqual(DriveAPI.mediaURL(fileId: "x").absoluteString, "https://www.googleapis.com/drive/v3/files/x?alt=media&supportsAllDrives=true")
    }
}
