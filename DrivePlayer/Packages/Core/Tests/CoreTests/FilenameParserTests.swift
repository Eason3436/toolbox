import XCTest
@testable import Core

final class FilenameParserTests: XCTestCase {
    private func movie(
        _ file: String, _ title: String, _ year: Int?, tags: [QualityTag]? = nil,
        folders: [String] = [], line: UInt = #line
    ) {
        let r = FilenameParser.parse(file, parentFolders: folders)
        XCTAssertEqual(r.kind, .movie, "kind: \(file)", line: line)
        XCTAssertEqual(r.title, title, "title: \(file)", line: line)
        XCTAssertEqual(r.year, year, "year: \(file)", line: line)
        if let tags { XCTAssertEqual(r.tags, tags, "tags: \(file)", line: line) }
    }

    private func episode(
        _ file: String, _ title: String, season: Int, episode: Int, year: Int? = nil,
        end: Int? = nil, tags: [QualityTag]? = nil, folders: [String] = [], line: UInt = #line
    ) {
        let r = FilenameParser.parse(file, parentFolders: folders)
        XCTAssertEqual(r.kind, .episode, "kind: \(file)", line: line)
        XCTAssertEqual(r.title, title, "title: \(file)", line: line)
        XCTAssertEqual(r.season, season, "season: \(file)", line: line)
        XCTAssertEqual(r.episode, episode, "episode: \(file)", line: line)
        XCTAssertEqual(r.year, year, "year: \(file)", line: line)
        XCTAssertEqual(r.episodeEnd, end, "episodeEnd: \(file)", line: line)
        if let tags { XCTAssertEqual(r.tags, tags, "tags: \(file)", line: line) }
    }

    // MARK: 規劃書的四個範例

    func testPlanExamples() {
        movie("Zootopia.2.2025.2160p.DV.Atmos.mp4", "Zootopia 2", 2025, tags: [.uhd4K, .dolbyVision, .atmos])
        episode("The.Bear.S03E05.1080p.WEB-DL.mp4", "The Bear", season: 3, episode: 5, tags: [.fullHD])
        movie("動物方城市2 (2025).mp4", "動物方城市2", 2025, tags: [])
        episode("[字幕組] 葬送的芙莉蓮 - 12 [1080p].mp4", "葬送的芙莉蓮", season: 1, episode: 12, tags: [.fullHD])
    }

    // MARK: 英文電影

    func testSceneMovie() {
        movie("Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.HDR10.DV.HEVC.TrueHD.7.1.Atmos-GROUP.mp4",
              "Dune Part Two", 2024, tags: [.uhd4K, .dolbyVision, .hdr10, .atmos, .hevc])
    }

    func testNumberInTitleBeforeYear() {
        movie("Blade.Runner.2049.2017.2160p.mp4", "Blade Runner 2049", 2017, tags: [.uhd4K])
    }

    func testTitleIsAYear() {
        movie("1917.2019.1080p.mp4", "1917", 2019, tags: [.fullHD])
        movie("1917.mov", "1917", nil)
    }

    func testTitleStartsWithNumber() {
        movie("2001.A.Space.Odyssey.1968.mp4", "2001 A Space Odyssey", 1968)
    }

    func testParenYearAndBracketTags() {
        movie("Oppenheimer (2023) [2160p] [HDR10].m4v", "Oppenheimer", 2023, tags: [.uhd4K, .hdr10])
    }

    func testUnderscores() {
        movie("the_matrix_1999_1080p.mp4", "the matrix", 1999, tags: [.fullHD])
    }

    func testHDR10Plus() {
        movie("Avatar.The.Way.of.Water.2022.2160p.HDR10+.mp4", "Avatar The Way of Water", 2022, tags: [.uhd4K, .hdr10Plus])
    }

    func testPlainHDRAndHEVC() {
        movie("Inception.2010.1080p.BluRay.x265.mp4", "Inception", 2010, tags: [.fullHD, .hevc])
        movie("Movie.Name.2019.HDR.mp4", "Movie Name", 2019, tags: [.hdr])
    }

    func testTitleWordsThatLookLikeTags() {
        movie("Mad.Max.Fury.Road.2015.mp4", "Mad Max Fury Road", 2015)
        movie("Spider-Man.Across.the.Spider-Verse.2023.mp4", "Spider-Man Across the Spider-Verse", 2023)
    }

    func testNoYearCutsAtJunk() {
        movie("Some Movie WEB-DL 1080p.mp4", "Some Movie", nil, tags: [.fullHD])
    }

    // MARK: 中文、日文電影

    func testChineseAndEnglishTitle() {
        movie("寄生上流 Parasite (2019).mp4", "寄生上流 Parasite", 2019)
    }

    func testJapaneseMovie() {
        movie("千と千尋の神隠し (2001).mp4", "千と千尋の神隠し", 2001)
    }

    func testFullWidthParens() {
        movie("你的名字（2016）.mov", "你的名字", 2016)
    }

    func testChineseMovieWith4K() {
        movie("沙丘2.2024.4K.HDR.mp4", "沙丘2", 2024, tags: [.uhd4K, .hdr])
    }

    // MARK: 英文劇集

    func testSceneEpisodeWithEpisodeTitle() {
        episode("Breaking.Bad.S05E14.Ozymandias.720p.mp4", "Breaking Bad", season: 5, episode: 14, tags: [.hd])
    }

    func testEpisodeWithYearAndManyTags() {
        episode("Shogun.2024.S01E01.2160p.DSNP.WEB-DL.DDP5.1.DV.HDR.H.265.mp4", "Shogun",
                season: 1, episode: 1, year: 2024, tags: [.uhd4K, .dolbyVision, .hdr, .hevc])
    }

    func testDoubleEpisode() {
        episode("Severance.S02E01E02.mp4", "Severance", season: 2, episode: 1, end: 2)
        episode("Severance.S02E03-E04.mp4", "Severance", season: 2, episode: 3, end: 4)
    }

    func testLowercase() {
        episode("friends.s01e01.mp4", "friends", season: 1, episode: 1)
    }

    func testNxNN() {
        episode("The Office 3x05.mp4", "The Office", season: 3, episode: 5)
    }

    func testDashSeparatedEpisode() {
        episode("The Last of Us - S01E03 - Long Long Time.mp4", "The Last of Us", season: 1, episode: 3)
    }

    func testYearInShowName() {
        episode("Doctor.Who.2005.S01E01.mp4", "Doctor Who", season: 1, episode: 1, year: 2005)
    }

    func testDoViTag() {
        episode("The.Mandalorian.S03E08.DoVi.mp4", "The Mandalorian", season: 3, episode: 8, tags: [.dolbyVision])
    }

    func testEPNumber() {
        episode("Some Show EP07.mp4", "Some Show", season: 1, episode: 7)
    }

    func testSeasonEpisodeWords() {
        episode("Lost Season 2 Episode 3.mp4", "Lost", season: 2, episode: 3)
    }

    // MARK: 中文劇集

    func testChineseEpisode() {
        episode("繁花 第12集.mp4", "繁花", season: 1, episode: 12)
        episode("甄嬛傳 第1集.mov", "甄嬛傳", season: 1, episode: 1)
    }

    func testChineseSeasonAndEpisode() {
        episode("慶餘年 第二季 第05集 4K.mp4", "慶餘年", season: 2, episode: 5, tags: [.uhd4K])
    }

    func testChineseArabicSeason() {
        episode("進擊的巨人 第3季 第10話.mp4", "進擊的巨人", season: 3, episode: 10)
    }

    // MARK: 日文動畫

    func testJapaneseEpisode() {
        episode("鬼滅の刃 第26話.mp4", "鬼滅の刃", season: 1, episode: 26)
    }

    func testSubsPleaseStyle() {
        episode("[SubsPlease] Sousou no Frieren - 05 (1080p) [ABCD1234].mkv", "Sousou no Frieren",
                season: 1, episode: 5, tags: [.fullHD])
    }

    func testAllBracketsStyle() {
        episode("[Nekomoe kissaten][Kusuriya no Hitorigoto][13][1080p][CHT].mp4", "Kusuriya no Hitorigoto",
                season: 1, episode: 13, tags: [.fullHD])
    }

    func testTrailingSSeason() {
        episode("[SubsPlease] Spy x Family S2 - 03 [1080p].mp4", "Spy x Family", season: 2, episode: 3)
    }

    func testChineseSeasonWithDash() {
        episode("【喵萌奶茶屋】药屋少女的呢喃 第二季 - 05 [1080p].mp4", "药屋少女的呢喃", season: 2, episode: 5)
    }

    func testOrdinalSeason() {
        episode("Oshi no Ko 2nd Season - 04.mp4", "Oshi no Ko", season: 2, episode: 4)
    }

    func testBahaStyle() {
        episode("[ANi] 葬送的芙莉蓮 - 12 [1080P][Baha][WEB-DL][AAC AVC][CHT].mp4", "葬送的芙莉蓮",
                season: 1, episode: 12, tags: [.fullHD])
    }

    func testVersionSuffix() {
        episode("[Group] Bocchi the Rock! - 07v2 [1080p].mp4", "Bocchi the Rock!", season: 1, episode: 7)
    }

    // MARK: 資料夾線索

    func testShowFromFolder() {
        episode("S01E05.mp4", "The Bear", season: 1, episode: 5, folders: ["Season 1", "The Bear"])
    }

    func testNumberOnlyInChineseSeasonFolder() {
        episode("05.mp4", "慶餘年", season: 2, episode: 5, folders: ["第二季", "慶餘年"])
    }

    func testSpecialsFolderAndYearInShowFolder() {
        episode("E03.mp4", "Some Show", season: 0, episode: 3, year: 2020, folders: ["Specials", "Some Show (2020)"])
    }

    func testFolderSeasonOverridesDefault() {
        episode("葬送的芙莉蓮 - 30.mp4", "葬送的芙莉蓮", season: 2, episode: 30, folders: ["Season 02", "葬送的芙莉蓮"])
    }

    func testFilenameSeasonWinsOverFolder() {
        episode("The.Bear.S03E01.mp4", "The Bear", season: 3, episode: 1, folders: ["Season 1"])
    }

    func testChineseEpisodeOnlyWithFolder() {
        episode("第08集.mp4", "繁花", season: 1, episode: 8, folders: ["繁花"])
    }

    // MARK: 不該被當成劇集

    func testSequelNumberIsNotEpisode() {
        movie("Toy Story 4 (2019).mp4", "Toy Story 4", 2019)
        movie("Toy.Story.4.mp4", "Toy Story 4", nil)
    }

    // MARK: 小工具

    func testSeasonFromFolder() {
        XCTAssertEqual(FilenameParser.seasonFromFolder("Season 1"), 1)
        XCTAssertEqual(FilenameParser.seasonFromFolder("S02"), 2)
        XCTAssertEqual(FilenameParser.seasonFromFolder("第十二季"), 12)
        XCTAssertEqual(FilenameParser.seasonFromFolder("Specials"), 0)
        XCTAssertEqual(FilenameParser.seasonFromFolder("Season 01 (2022)"), 1)
        XCTAssertNil(FilenameParser.seasonFromFolder("The Bear"))
        XCTAssertNil(FilenameParser.seasonFromFolder("Movies"))
    }

    func testChineseNumbers() {
        XCTAssertEqual(ChineseNumber.parse("一"), 1)
        XCTAssertEqual(ChineseNumber.parse("十"), 10)
        XCTAssertEqual(ChineseNumber.parse("十二"), 12)
        XCTAssertEqual(ChineseNumber.parse("二十"), 20)
        XCTAssertEqual(ChineseNumber.parse("兩"), 2)
        XCTAssertEqual(ChineseNumber.parse("一百零五"), 105)
        XCTAssertEqual(ChineseNumber.parse("05"), 5)
        XCTAssertNil(ChineseNumber.parse("abc"))
    }
}
