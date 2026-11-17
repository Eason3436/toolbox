import Testing
import Foundation
import SwiftData
@testable import Sweep

/// 固定種子的亂數，讓洗牌結果可以重現
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct ShufflerTests {
    @Test func picksRequestedSizeWithoutDuplicates() {
        var rng = SeededGenerator(state: 1)
        let ids = (0..<100).map { "a\($0)" }
        let group = Shuffler.group(from: ids, excluding: [], size: 15, using: &rng)
        #expect(group.count == 15)
        #expect(Set(group).count == 15)
        #expect(Set(group).isSubset(of: Set(ids)))
    }

    @Test func respectsExclusions() {
        var rng = SeededGenerator(state: 7)
        let ids = (0..<20).map { "a\($0)" }
        let excluded = Set(ids.prefix(18))
        let group = Shuffler.group(from: ids, excluding: excluded, size: 15, using: &rng)
        #expect(Set(group) == ["a18", "a19"])
    }

    @Test func emptyWhenEverythingExcluded() {
        let group = Shuffler.group(from: ["a", "b"], excluding: ["a", "b"], size: 5)
        #expect(group.isEmpty)
    }

    @Test func notAlwaysTheSameOrder() {
        let ids = (0..<200).map { "a\($0)" }
        var a = SeededGenerator(state: 1)
        var b = SeededGenerator(state: 2)
        #expect(Shuffler.group(from: ids, excluding: [], size: 15, using: &a)
                != Shuffler.group(from: ids, excluding: [], size: 15, using: &b))
    }
}

struct RelativeDayTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func days() {
        let now = date(2026, 11, 17, 9)
        #expect(RelativeDay.text(for: date(2026, 11, 17, 1), now: now, calendar: calendar) == "今天")
        #expect(RelativeDay.text(for: date(2026, 11, 16, 23), now: now, calendar: calendar) == "昨天")
        #expect(RelativeDay.text(for: date(2026, 8, 24), now: now, calendar: calendar) == "85 天前")
        #expect(RelativeDay.text(for: date(2024, 11, 1), now: now, calendar: calendar) == "2 年前")
    }
}

struct PlaceFormatterTests {
    @Test func countyAndVillage() {
        #expect(PlaceFormatter.short(fromFull: "500台灣彰化縣彰化市南瑤里中華路1號") == "彰化縣南瑤里")
    }

    @Test func countyAndDistrict() {
        #expect(PlaceFormatter.short(fromFull: "106臺北市大安區羅斯福路四段1號") == "臺北市大安區")
        #expect(PlaceFormatter.district(fromFull: "106臺北市大安區羅斯福路四段1號") == "臺北市大安區")
    }

    @Test func foreignAddressFallsBack() {
        #expect(PlaceFormatter.short(fromFull: "1 Apple Park Way, Cupertino, CA 95014") == nil)
    }
}

struct ExifSummaryTests {
    @Test func readsCameraValues() {
        let props: [String: Any] = [
            "{TIFF}": ["Make": "Apple", "Model": "iPhone 17 Pro Max"],
            "{Exif}": [
                "FNumber": NSNumber(value: 1.78),
                "ExposureTime": NSNumber(value: 1.0 / 120),
                "ISOSpeedRatings": [NSNumber(value: 64)],
                "FocalLength": NSNumber(value: 6.86),
                "FocalLenIn35mmFilm": NSNumber(value: 24),
                "LensModel": "iPhone 17 Pro Max back triple camera 6.86mm f/1.78",
            ],
        ]
        let exif = ExifSummary(properties: props)
        #expect(exif.device == "Apple iPhone 17 Pro Max")
        #expect(exif.exposureText == "1/120 秒")
        #expect(exif.isoText == "ISO 64")
        #expect(exif.focalText == "24 mm")
        #expect(exif.parameters.count == 4)
    }

    @Test func modelAlreadyContainsMake() {
        let exif = ExifSummary(properties: ["{TIFF}": ["Make": "SONY", "Model": "Sony ILCE-7M4"]])
        #expect(exif.device == "Sony ILCE-7M4")
        #expect(exif.parameters.isEmpty)
    }
}

@MainActor
struct VideoFeedTests {
    @Test func removingCurrentMovesToNext() {
        let feed = VideoFeedModel()
        feed.setIDs(["a", "b", "c", "d"])
        let next = feed.removeDeleted(["b", "c"], current: "b")
        #expect(next == "d")
        #expect(feed.ids == ["a", "d"])
    }

    @Test func removingLastMovesBack() {
        let feed = VideoFeedModel()
        feed.setIDs(["a", "b"])
        #expect(feed.removeDeleted(["b"], current: "b") == "a")
    }

    @Test func neighbors() {
        let feed = VideoFeedModel()
        feed.setIDs(["a", "b", "c"])
        #expect(feed.neighbors(of: "a") == ["b"])
        #expect(feed.neighbors(of: "b") == ["a", "c"])
    }
}

@MainActor
struct StatsRecorderTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ViewedAsset.self, CleanStats.self, configurations: config)
        return ModelContext(container)
    }

    @Test func viewedCountsOncePerAsset() throws {
        let context = try makeContext()
        StatsRecorder.recordViewed("x", kind: .photo, context: context)
        StatsRecorder.recordViewed("x", kind: .photo, context: context)
        StatsRecorder.recordViewed("y", kind: .screenshot, context: context)
        #expect(StatsRecorder.stats(for: .photo, context: context).viewedCount == 1)
        #expect(StatsRecorder.stats(for: .screenshot, context: context).viewedCount == 1)
        #expect(StatsRecorder.viewedIDs(context: context) == ["x", "y"])
    }

    @Test func deletionAddsBytes() throws {
        let context = try makeContext()
        StatsRecorder.recordViewed("v", kind: .video, context: context)
        StatsRecorder.recordDeleted([(id: "v", kind: .video, bytes: 1_000), (id: "w", kind: .video, bytes: 500)], context: context)
        let stats = StatsRecorder.stats(for: .video, context: context)
        #expect(stats.deletedCount == 2)
        #expect(stats.freedBytes == 1_500)
        #expect(stats.viewedCount == 2)
    }

    @Test func resetKeepsStats() throws {
        let context = try makeContext()
        StatsRecorder.recordViewed("x", kind: .photo, context: context)
        StatsRecorder.resetViewed(context: context)
        #expect(StatsRecorder.viewedIDs(context: context).isEmpty)
        #expect(StatsRecorder.stats(for: .photo, context: context).viewedCount == 1)
    }
}
