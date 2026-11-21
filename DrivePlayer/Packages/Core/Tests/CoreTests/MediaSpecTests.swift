import XCTest
@testable import Core

private func bits(_ fields: [(Int, Int)]) -> [UInt8] {
    var out: [UInt8] = []
    var current: UInt8 = 0
    var count = 0
    for (value, width) in fields {
        for i in stride(from: width - 1, through: 0, by: -1) {
            current = (current << 1) | UInt8((value >> i) & 1)
            count += 1
            if count == 8 { out.append(current); current = 0; count = 0 }
        }
    }
    if count > 0 { out.append(current << (8 - count)) }
    return out
}

final class DolbyAudioTests: XCTestCase {
    /// 一個獨立子串流：fscod bsid reserved asvc bsmod acmod lfeon reserved num_dep_sub
    private func substream(acmod: Int, lfe: Int, dep: Int = 0, chanLoc: Int = 0) -> [(Int, Int)] {
        var f: [(Int, Int)] = [(0, 2), (16, 5), (0, 1), (0, 1), (0, 3), (acmod, 3), (lfe, 1), (0, 3), (dep, 4)]
        f.append(dep > 0 ? (chanLoc, 9) : (0, 1))
        return f
    }

    func testEAC3With51Atmos() {
        let data = bits([(768, 13), (0, 3)] + substream(acmod: 7, lfe: 1) + [(0, 7), (1, 1), (16, 8)])
        let info = DolbyAudioConfig.parseDEC3(data)
        XCTAssertEqual(info, .init(channels: 6, hasLFE: true, isAtmos: true))
    }

    func testEAC3Without_JOC() {
        let data = bits([(768, 13), (0, 3)] + substream(acmod: 7, lfe: 1))
        XCTAssertEqual(DolbyAudioConfig.parseDEC3(data)?.isAtmos, false)
        XCTAssertEqual(DolbyAudioConfig.parseDEC3(data)?.channels, 6)
    }

    func testEAC3_71WithDependentSubstream() {
        // chan_loc 第二個位元：Lrs/Rrs
        let data = bits([(1024, 13), (0, 3)] + substream(acmod: 7, lfe: 1, dep: 1, chanLoc: 0b0_1000_0000))
        XCTAssertEqual(DolbyAudioConfig.parseDEC3(data)?.channels, 8)
    }

    func testAC3Stereo() {
        let data = bits([(0, 2), (8, 5), (0, 3), (2, 3), (0, 1), (0, 5), (0, 5)])
        XCTAssertEqual(DolbyAudioConfig.parseDAC3(data), .init(channels: 2, hasLFE: false, isAtmos: false))
    }

    func testLayoutNames() {
        XCTAssertEqual(DolbyAudioConfig.layoutName(channels: 6), "5.1")
        XCTAssertEqual(DolbyAudioConfig.layoutName(channels: 8), "7.1")
        XCTAssertEqual(DolbyAudioConfig.layoutName(channels: 2), "立體聲")
    }
}

final class SubtitleTests: XCTestCase {
    func testSRT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        <i>你好</i>

        2
        00:00:04,000 --> 00:00:06,000
        第一行
        第二行
        """
        let track = SubtitleParser.parse(srt, fileExtension: "srt")
        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.text(at: 2), "你好")
        XCTAssertNil(track.text(at: 3.7))
        XCTAssertEqual(track.text(at: 5), "第一行\n第二行")
    }

    func testVTT() {
        let vtt = "WEBVTT\r\n\r\n00:01.000 --> 00:02.000 align:center\r\nHello\r\n"
        let track = SubtitleParser.parse(vtt, fileExtension: "vtt")
        XCTAssertEqual(track.text(at: 1.5), "Hello")
    }

    func testASS() {
        let ass = """
        [Script Info]
        Title: x

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\an8\\fs20}上面,還有逗號\\N第二行
        """
        let track = SubtitleParser.parse(ass, fileExtension: "ass")
        XCTAssertEqual(track.text(at: 2), "上面,還有逗號\n第二行")
    }

    func testOverlappingCues() {
        let track = SubtitleTrack(cues: [
            SubtitleCue(start: 0, end: 10, text: "A"),
            SubtitleCue(start: 2, end: 3, text: "B"),
        ])
        XCTAssertEqual(track.text(at: 2.5), "A\nB")
        XCTAssertEqual(track.text(at: 5), "A")
    }

    func testFileMatching() {
        XCTAssertTrue(SubtitleParser.matches(subtitleName: "Movie.2019.srt", videoName: "Movie.2019.mp4"))
        XCTAssertTrue(SubtitleParser.matches(subtitleName: "Movie.2019.zh-TW.srt", videoName: "Movie.2019.mp4"))
        XCTAssertFalse(SubtitleParser.matches(subtitleName: "Movie.2020.srt", videoName: "Movie.2019.mp4"))
    }

    func testLanguagePick() {
        let options: [(languageTag: String?, name: String)] = [
            ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"),
        ]
        XCTAssertEqual(MediaLanguage.traditionalChinese.bestIndex(options), 2)
        XCTAssertEqual(MediaLanguage.simplifiedChinese.bestIndex(options), 1)
        XCTAssertEqual(MediaLanguage.english.bestIndex(options), 0)
        XCTAssertNil(MediaLanguage.korean.bestIndex(options))
        let files: [(languageTag: String?, name: String)] = [(nil, "Movie.chs.srt"), (nil, "Movie.cht.srt")]
        XCTAssertEqual(MediaLanguage.traditionalChinese.bestIndex(files), 1)
    }
}

final class TMDBExtrasTests: XCTestCase {
    func testLogoAndDirectors() throws {
        let json = """
        {"id":1,"title":"x","original_language":"ja","origin_country":["JP"],
         "credits":{"cast":[],"crew":[{"id":9,"name":"導演甲","job":"Director"},{"id":8,"name":"編劇","job":"Writer"}]},
         "images":{"logos":[
           {"file_path":"/en.png","iso_639_1":"en","vote_average":5},
           {"file_path":"/ja.svg","iso_639_1":"ja","vote_average":9},
           {"file_path":"/zh.png","iso_639_1":"zh","iso_3166_1":"TW","vote_average":1}]}}
        """
        let d = try TMDB.decoder.decode(TMDBMovieDetails.self, from: Data(json.utf8))
        XCTAssertEqual(d.images?.bestLogo(originalLanguage: d.originalLanguage), "/zh.png")
        XCTAssertEqual(d.credits?.directors.map(\.name), ["導演甲"])
        XCTAssertEqual(d.countryCode, "JP")
        let noZh = TMDBImages(logos: [TMDBImage(filePath: "/ja.svg", iso6391: "ja")])
        XCTAssertEqual(noZh.bestLogo(originalLanguage: "ja"), "/ja.png")
    }
}
