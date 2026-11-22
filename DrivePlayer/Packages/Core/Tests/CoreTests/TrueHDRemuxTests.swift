import Foundation
import XCTest
@testable import Core

/// truehd-av.mp4：ffmpeg 做的 0.5 秒 H.264＋TrueHD 5.1（faststart）。
/// PCM 預期值是 `ffmpeg -i truehd-av.mp4 -map 0:a -f s24le` 的 FNV-1a 64
final class TrueHDRemuxTests: XCTestCase {
    private struct Setup {
        let file: [UInt8]
        let plan: TrueHDRemuxPlan
    }

    private func setup() throws -> Setup {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "truehd-av", withExtension: "mp4", subdirectory: "Fixtures"))
        let file = [UInt8](try Data(contentsOf: url))
        let top = Self.topLevel(file)
        let moovBox = try XCTUnwrap(top.first { $0.type == "moov" })
        let moov = Array(file[Int(moovBox.offset)..<Int(moovBox.offset + moovBox.size)])
        let track = try XCTUnwrap(TrueHDRemux.findTrack(moov: moov))
        XCTAssertEqual(track.table.sampleCount, 600)

        // 解第一個 sample 拿格式
        let decoder = TrueHDDecoder()
        let first = try XCTUnwrap(track.table.locations(0..<1).first)
        let bytes = Array(file[Int(first.offset)..<(Int(first.offset) + first.size)])
        for range in TrueHDDecoder.accessUnits(in: bytes) { _ = decoder.decode(bytes[range]) }
        let format = try XCTUnwrap(decoder.format)

        let plan = try XCTUnwrap(TrueHDRemux.plan(track: track, topLevel: top, fileSize: Int64(file.count), format: format))
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

    private func samples(_ setup: Setup, _ range: Range<Int>) -> [[UInt8]] {
        setup.plan.table.locations(range).map { Array(setup.file[Int($0.offset)..<(Int($0.offset) + $0.size)]) }
    }

    private func render(_ renderer: TrueHDPCMRenderer, _ setup: Setup, _ range: Range<Int64>) -> [UInt8] {
        let needed = renderer.samplesNeeded(for: range)
        return renderer.render(range, samples: samples(setup, needed), startingAt: needed.lowerBound)
    }

    private func fnv(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return h
    }

    func testPlanLayout() throws {
        let s = try setup()
        let plan = s.plan
        XCTAssertEqual(plan.format.channels, 6)
        XCTAssertEqual(plan.totalFrames, 24000)
        XCTAssertEqual(plan.bytesPerFrame, 18)
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
        let renderer = TrueHDPCMRenderer(plan: s.plan)
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
        let full = render(TrueHDPCMRenderer(plan: s.plan), s, 0..<total)

        let renderer = TrueHDPCMRenderer(plan: s.plan)
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
        let s = try setup()
        var virtual = s.file
        for (offset, byte) in s.plan.patches { virtual[Int(offset)] = byte }
        virtual.append(contentsOf: s.plan.header)
        virtual.append(contentsOf: render(TrueHDPCMRenderer(plan: s.plan), s, 0..<(s.plan.totalSize - s.plan.pcmStart)))
        try Data(virtual).write(to: URL(fileURLWithPath: path))
    }

    func testChannelLabels() {
        let side51 = AVCh.fl | AVCh.fr | AVCh.fc | AVCh.lfe | AVCh.sl | AVCh.sr
        XCTAssertEqual(TrueHDRemux.channelLabels(mask: side51), [1, 2, 3, 4, 5, 6])
        let back51 = AVCh.fl | AVCh.fr | AVCh.fc | AVCh.lfe | AVCh.bl | AVCh.br
        XCTAssertEqual(TrueHDRemux.channelLabels(mask: back51), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(TrueHDRemux.channelLabels(mask: side51 | AVCh.bl | AVCh.br), [1, 2, 3, 4, 33, 34, 5, 6])
    }

    func testPlayableAudioTrackSkipsRemux() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "truehd-av", withExtension: "mp4", subdirectory: "Fixtures"))
        let file = [UInt8](try Data(contentsOf: url))
        let moovBox = try XCTUnwrap(Self.topLevel(file).first { $0.type == "moov" })
        var moov = Array(file[Int(moovBox.offset)..<Int(moovBox.offset + moovBox.size)])
        // 把 mlpa 改成 ac-3：有能播的音軌就不轉
        let needle = Array("mlpa".utf8)
        let index = try XCTUnwrap((0...(moov.count - 4)).first { Array(moov[$0..<($0 + 4)]) == needle })
        moov.replaceSubrange(index..<(index + 4), with: Array("ac-3".utf8))
        XCTAssertNil(TrueHDRemux.findTrack(moov: moov))
    }
}
