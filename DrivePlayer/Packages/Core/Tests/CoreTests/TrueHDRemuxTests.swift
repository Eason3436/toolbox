import Foundation
import XCTest
@testable import Core

/// truehd-av.mp4：ffmpeg 做的 0.5 秒 H.264＋TrueHD 5.1（faststart）。
/// truehd-multi.mp4：同一段影片＋AAC＋上面那條 TrueHD 5.1＋ffmpeg 編的 TrueHD 立體聲。
/// PCM 預期值是 `ffmpeg -i X.mp4 -map 0:N -f s24le` 的 FNV-1a 64
final class TrueHDRemuxTests: XCTestCase {
    private struct Setup {
        let file: [UInt8]
        let plan: TrueHDRemuxPlan
        var track: TrueHDTrackPlan { plan.tracks[0] }
    }

    private func setup(_ name: String = "truehd-av") throws -> Setup {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
        let file = [UInt8](try Data(contentsOf: url))
        let top = Self.topLevel(file)
        let moovBox = try XCTUnwrap(top.first { $0.type == "moov" })
        let moov = Array(file[Int(moovBox.offset)..<Int(moovBox.offset + moovBox.size)])
        let tracks = try XCTUnwrap(TrueHDRemux.findTracks(moov: moov))

        // 解第一個 sample 拿格式
        let formats = tracks.tracks.map { track -> TrueHDFormat? in
            let decoder = TrueHDDecoder()
            guard let first = track.table.locations(0..<1).first else { return nil }
            let bytes = Array(file[Int(first.offset)..<(Int(first.offset) + first.size)])
            for range in TrueHDDecoder.accessUnits(in: bytes) { _ = decoder.decode(bytes[range]) }
            return decoder.format
        }

        let plan = try XCTUnwrap(TrueHDRemux.plan(tracks: tracks, formats: formats, topLevel: top, fileSize: Int64(file.count)))
        return Setup(file: file, plan: plan)
    }

    static func topLevel(_ file: [UInt8]) -> [TrueHDRemux.TopLevelBox] {
        var out: [TrueHDRemux.TopLevelBox] = []
        var p: Int64 = 0
        while p + 8 <= Int64(file.count), let h = MP4Boxes.header(file, at: Int(p)) {
            let size = h.size == 0 ? Int64(file.count) - p : h.size
            out.append(.init(type: h.type, offset: p, size: size))
            p += size
        }
        return out
    }

    private func samples(_ setup: Setup, _ track: TrueHDTrackPlan, _ range: Range<Int>) -> [[UInt8]] {
        track.table.locations(range).map { Array(setup.file[Int($0.offset)..<(Int($0.offset) + $0.size)]) }
    }

    private func render(_ renderer: TrueHDPCMRenderer, _ setup: Setup, _ range: Range<Int64>) -> [UInt8] {
        let needed = renderer.samplesNeeded(for: range)
        return renderer.render(range, samples: samples(setup, renderer.plan, needed), startingAt: needed.lowerBound)
    }

    private func fnv(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return h
    }

    func testPlanLayout() throws {
        let s = try setup()
        let plan = s.plan
        XCTAssertEqual(plan.tracks.count, 1)
        XCTAssertEqual(s.track.table.sampleCount, 600)
        XCTAssertEqual(s.track.format.channels, 6)
        XCTAssertEqual(s.track.totalFrames, 24000)
        XCTAssertEqual(s.track.bytesPerFrame, 18)
        XCTAssertEqual(plan.totalSize, plan.pcmStart + 24000 * 18)
        XCTAssertEqual(plan.originalSize + Int64(plan.header.count), plan.pcmStart)

        // 虛擬檔案的頂層盒子：原本的照舊（moov 變 free），後面接新的 moov 和 PCM 的 mdat
        var virtual = s.file
        for (offset, byte) in plan.patches { virtual[Int(offset)] = byte }
        virtual.append(contentsOf: plan.header)
        let top = Self.topLevel(virtual)
        XCTAssertEqual(top.map(\.type), ["ftyp", "free", "free", "mdat", "moov", "mdat"])
        XCTAssertEqual(Array(virtual[8..<12]), Array("qt  ".utf8))
        XCTAssertEqual(top.last.map { $0.offset + $0.size }, plan.totalSize)

        // 新的 moov：影片軌原封不動，音軌換成 lpcm
        let moov = try XCTUnwrap(top.first { $0.type == "moov" })
        let tree = try XCTUnwrap(MP4Box.parse(virtual[Int(moov.offset)..<Int(moov.offset + moov.size)])?.first)
        let traks = tree.children.filter { $0.type == "trak" }
        XCTAssertEqual(traks.compactMap(TrueHDRemux.sampleEntryType), ["avc1", "lpcm"])
        let stbl = try XCTUnwrap(traks[1].find("mdia/minf/stbl"))
        XCTAssertEqual(stbl.children.map(\.type), ["stsd", "stts", "stsc", "stsz", "co64"])
        let table = try XCTUnwrap(MP4SampleTable(stbl: stbl, timescale: 48000))
        XCTAssertEqual(table.sampleCount, 24000)
        XCTAssertEqual(table.locations(0..<1).first?.offset, plan.pcmStart)
        XCTAssertEqual(table.locations(23999..<24000).first?.offset, plan.pcmStart + 23999 * 18)
    }

    func testFullRenderMatchesFFmpeg() throws {
        let s = try setup()
        let renderer = TrueHDPCMRenderer(plan: s.track)
        let total = s.plan.totalSize - s.plan.pcmStart
        var pcm: [UInt8] = []
        // 照播放器那樣一段一段讀，邊界故意不對齊 sample
        var pos: Int64 = 0
        while pos < total {
            let end = min(total, pos + 50_003)
            pcm.append(contentsOf: render(renderer, s, pos..<end))
            pos = end
        }
        XCTAssertEqual(pcm.count, 432_000)
        XCTAssertEqual(fnv(pcm), 0xa94c_2f65_7de9_4ccb)
    }

    func testRandomAccessMatchesSequential() throws {
        let s = try setup()
        let total = s.plan.totalSize - s.plan.pcmStart
        let full = render(TrueHDPCMRenderer(plan: s.track), s, 0..<total)

        let renderer = TrueHDPCMRenderer(plan: s.track)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let start = Int64.random(in: 0..<(total - 1), using: &generator)
            let end = min(total, start + Int64.random(in: 1...30_000, using: &generator))
            XCTAssertEqual(render(renderer, s, start..<end), Array(full[Int(start)..<Int(end)]), "\(start)..<\(end)")
        }
    }

    /// 設了 TRUEHD_DUMP 就把整個虛擬檔案寫出來（給 ffprobe／QuickTime 檢查）
    func testDumpVirtualFile() throws {
        guard let path = ProcessInfo.processInfo.environment["TRUEHD_DUMP"] else { return }
        for name in ["truehd-av", "truehd-multi"] {
            let s = try setup(name)
            try Data(virtualFile(s)).write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".mov"))
        }
    }

    func testChannelLabels() {
        let side51 = AVCh.fl | AVCh.fr | AVCh.fc | AVCh.lfe | AVCh.sl | AVCh.sr
        XCTAssertEqual(TrueHDRemux.channelLabels(mask: side51), [1, 2, 3, 4, 5, 6])
        let back51 = AVCh.fl | AVCh.fr | AVCh.fc | AVCh.lfe | AVCh.bl | AVCh.br
        XCTAssertEqual(TrueHDRemux.channelLabels(mask: back51), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(TrueHDRemux.channelLabels(mask: side51 | AVCh.bl | AVCh.br), [1, 2, 3, 4, 33, 34, 5, 6])
    }

    private func virtualFile(_ s: Setup) -> [UInt8] {
        var virtual = s.file
        for (offset, byte) in s.plan.patches { virtual[Int(offset)] = byte }
        virtual.append(contentsOf: s.plan.header)
        for track in s.plan.tracks {
            virtual.append(contentsOf: render(TrueHDPCMRenderer(plan: track), s, 0..<(track.pcmEnd - track.pcmStart)))
        }
        return virtual
    }

    /// 好幾條 TrueHD 都轉，旁邊能播的 AAC 照舊
    func testMultipleTracks() throws {
        let s = try setup("truehd-multi")
        XCTAssertEqual(s.plan.tracks.map(\.format.channels), [6, 2])
        XCTAssertEqual(s.plan.tracks.map(\.trackID), [3, 4])
        XCTAssertEqual(s.plan.tracks[0].pcmEnd, s.plan.tracks[1].pcmStart)
        XCTAssertEqual(s.plan.tracks[1].pcmEnd, s.plan.totalSize)
        XCTAssertEqual(s.plan.track(containing: s.plan.tracks[1].pcmStart)?.trackID, 4)

        let virtual = virtualFile(s)
        XCTAssertEqual(Int64(virtual.count), s.plan.totalSize)
        let top = Self.topLevel(virtual)
        let moov = try XCTUnwrap(top.first { $0.type == "moov" })
        let tree = try XCTUnwrap(MP4Box.parse(virtual[Int(moov.offset)..<Int(moov.offset + moov.size)])?.first)
        XCTAssertEqual(tree.children.filter { $0.type == "trak" }.compactMap(TrueHDRemux.sampleEntryType),
                       ["avc1", "mp4a", "lpcm", "lpcm"])

        let expected: [(Int, UInt64)] = [(432_000, 0xa94c_2f65_7de9_4ccb), (144_000, 0x7167_c3fd_419c_2d7b)]
        for (track, (count, hash)) in zip(s.plan.tracks, expected) {
            let pcm = Array(virtual[Int(track.pcmStart)..<Int(track.pcmEnd)])
            XCTAssertEqual(pcm.count, count)
            XCTAssertEqual(fnv(pcm), hash)
        }
    }

    func testNoTrueHDTrack() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "truehd-av", withExtension: "mp4", subdirectory: "Fixtures"))
        let file = [UInt8](try Data(contentsOf: url))
        let moovBox = try XCTUnwrap(Self.topLevel(file).first { $0.type == "moov" })
        var moov = Array(file[Int(moovBox.offset)..<Int(moovBox.offset + moovBox.size)])
        let needle = Array("mlpa".utf8)
        let index = try XCTUnwrap((0...(moov.count - 4)).first { Array(moov[$0..<($0 + 4)]) == needle })
        moov.replaceSubrange(index..<(index + 4), with: Array("ac-3".utf8))
        XCTAssertNil(TrueHDRemux.findTracks(moov: moov))
    }
}
