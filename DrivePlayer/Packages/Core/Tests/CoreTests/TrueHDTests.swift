import Foundation
import XCTest
@testable import Core

/// 測試檔：
/// - dolby-51.thd：FFmpeg FATE 的 lossless-audio/truehd_5.1.raw 前 615 個 AU（杜比編碼器，5.1）
/// - dolby-atmos.thd：FATE 的 truehd/atmos.thd（杜比全景聲，解 7.1 底層）
/// - ffmpeg-51.thd：ffmpeg 自己的 TrueHD 編碼器產生的 5.1
/// 預期值是 `ffmpeg -f truehd -i X.thd -f s32le` 的結果（右移 8 位元還原成 24-bit）算 FNV-1a 64
final class TrueHDTests: XCTestCase {
    private func fixture(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "thd", subdirectory: "Fixtures"))
        return [UInt8](try Data(contentsOf: url))
    }

    /// 解整個檔案，回傳所有 AU 的 PCM 串起來
    private func decodeAll(_ bytes: [UInt8], from first: Int = 0) -> (samples: [Int32], format: TrueHDFormat?, decoded: Int) {
        let decoder = TrueHDDecoder()
        var out: [Int32] = []
        var decoded = 0
        for range in TrueHDDecoder.accessUnits(in: bytes).dropFirst(first) {
            if decoder.decode(bytes[range]) != nil {
                out.append(contentsOf: decoder.output)
                decoded += 1
            }
        }
        return (out, decoder.format, decoded)
    }

    private func fnv(_ samples: [Int32]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for s in samples {
            let v = UInt32(bitPattern: s)
            for shift in stride(from: 0, to: 32, by: 8) {
                h ^= UInt64((v >> UInt32(shift)) & 0xFF)
                h = h &* 0x100_0000_01b3
            }
        }
        return h
    }

    func testDolby51MatchesFFmpeg() throws {
        let result = decodeAll(try fixture("dolby-51"))
        XCTAssertEqual(result.samples.count, 144_480)
        XCTAssertEqual(fnv(result.samples), 0x8d95_c9a1_2b53_de65)
        let format = try XCTUnwrap(result.format)
        XCTAssertEqual(format.sampleRate, 48000)
        XCTAssertEqual(format.channels, 6)
        XCTAssertEqual(format.channelMask, AVCh.fl | AVCh.fr | AVCh.fc | AVCh.lfe | AVCh.sl | AVCh.sr)
        XCTAssertFalse(format.isAtmos)
    }

    func testDolbyAtmosDecodes71Bed() throws {
        let result = decodeAll(try fixture("dolby-atmos"))
        XCTAssertEqual(result.samples.count, 40960)
        XCTAssertEqual(fnv(result.samples), 0x9014_2578_9046_ed94)
        let format = try XCTUnwrap(result.format)
        XCTAssertEqual(format.channels, 8)
        XCTAssertTrue(format.isAtmos)
    }

    func testFFmpegEncoded51MatchesFFmpeg() throws {
        let result = decodeAll(try fixture("ffmpeg-51"))
        XCTAssertEqual(result.samples.count, 69600)
        XCTAssertEqual(fnv(result.samples), 0x9a4f_47f1_7fd6_bfba)
    }

    /// 換位置播放：從中間的 major sync 開始解，結果要跟從頭解的同一段一模一樣
    func testRestartFromLaterMajorSync() throws {
        let bytes = try fixture("dolby-51")
        let units = TrueHDDecoder.accessUnits(in: bytes)
        let syncs = units.indices.filter { TrueHDDecoder.isMajorSync(bytes[units[$0]]) }
        XCTAssertGreaterThan(syncs.count, 3)
        let start = try XCTUnwrap(syncs.first { $0 > 300 })

        let full = decodeAll(bytes)
        let tail = decodeAll(bytes, from: start)
        XCTAssertEqual(tail.decoded, units.count - start)
        XCTAssertEqual(Array(full.samples.suffix(tail.samples.count)), tail.samples)
    }

    func testAccessUnitSplitting() {
        // 兩個 AU：長度欄位 = 長度 / 2
        let au1: [UInt8] = [0x00, 0x04, 0, 0, 1, 2, 3, 4]
        let au2: [UInt8] = [0x00, 0x02, 0, 0]
        XCTAssertEqual(TrueHDDecoder.accessUnits(in: au1 + au2), [0..<8, 8..<12])
        // 最後一個不完整的丟掉
        XCTAssertEqual(TrueHDDecoder.accessUnits(in: au1 + [0x00, 0x08, 0]), [0..<8])
    }
}
