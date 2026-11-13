import XCTest
@testable import Toolbox

/// 4K → 1080p 自動碼率的規則測試。預期值依規格手算：
/// 基準 = 寬 × 高 × 有效影格率 × bpp；複雜度 = clamp(原片 bpp / 0.09, 0.8, 1.4)；
/// 上下限 SDR 30fps 7–18 Mbps（依有效影格率調整、HDR ×1.25），且 ≤ 原片 60%。
final class BitrateCalculatorTests: XCTestCase {
    private func plan(_ width: Int, _ height: Int, fps: Double, hdr: Bool = false,
                      source: Double?) throws -> BitratePlan {
        try XCTUnwrap(BitrateCalculator.plan(sourceWidth: width, sourceHeight: height, frameRate: fps,
                                             isHDR: hdr, sourceVideoBitrate: source))
    }

    private func assertBitrate(_ actual: Int, _ expected: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(actual), expected, accuracy: 2, file: file, line: line)
    }

    // MARK: 4K30 SDR

    func test4K30SDR() throws {
        // iPhone 4K30 HEVC 約 45 Mbps → 原片 bpp ≈ 0.18 → 複雜度上限 1.4
        let p = try plan(3840, 2160, fps: 30, source: 45_000_000)
        XCTAssertEqual(p.width, 1920)
        XCTAssertEqual(p.height, 1080)
        XCTAssertEqual(p.complexity, 1.4, accuracy: 1e-9)
        assertBitrate(p.targetBitrate, 1920 * 1080 * 30 * 0.14 * 1.4) // ≈ 12.19 Mbps
        assertBitrate(p.peakBitrate, Double(p.targetBitrate) * 1.5)
        XCTAssertEqual(p.keyFrameInterval, 60)
        XCTAssertEqual(p.keyFrameDuration, 2)
    }

    // MARK: 4K60 SDR

    func test4K60SDR() throws {
        let p = try plan(3840, 2160, fps: 60, source: 90_000_000)
        let effective = 30 * pow(2.0, 0.75) // ≈ 50.45
        XCTAssertEqual(p.effectiveFrameRate, effective, accuracy: 1e-9)
        assertBitrate(p.targetBitrate, 1920 * 1080 * effective * 0.14 * 1.4) // ≈ 20.5 Mbps
        XCTAssertEqual(p.keyFrameInterval, 120)
        // 60fps 的上下限依有效影格率放大
        let bounds = BitrateCalculator.bounds(frameRate: 60, isHDR: false)
        XCTAssertEqual(bounds.lowerBound, 7_000_000 * effective / 30, accuracy: 1)
        XCTAssertEqual(bounds.upperBound, 18_000_000 * effective / 30, accuracy: 1)
        XCTAssertTrue(bounds.contains(Double(p.targetBitrate)))
    }

    // MARK: 4K30 HDR

    func test4K30HDR() throws {
        let p = try plan(3840, 2160, fps: 30, hdr: true, source: 50_000_000)
        assertBitrate(p.targetBitrate, 1920 * 1080 * 30 * 0.17 * 1.4) // ≈ 14.81 Mbps
        let bounds = BitrateCalculator.bounds(frameRate: 30, isHDR: true)
        XCTAssertEqual(bounds.lowerBound, 8_750_000, accuracy: 1)
        XCTAssertEqual(bounds.upperBound, 22_500_000, accuracy: 1)
    }

    // MARK: 直拍

    func testPortrait() throws {
        let portrait = try plan(2160, 3840, fps: 30, source: 45_000_000)
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)
        let landscape = try plan(3840, 2160, fps: 30, source: 45_000_000)
        XCTAssertEqual(portrait.targetBitrate, landscape.targetBitrate)
    }

    func testOutputSizeIsEven() throws {
        // DCI 4K（4096×2160）→ 2048×1080；不整除的比例要取偶數
        let dci = try XCTUnwrap(BitrateCalculator.outputSize(sourceWidth: 4096, sourceHeight: 2160))
        XCTAssertEqual(dci.width, 2048)
        XCTAssertEqual(dci.height, 1080)
        let odd = try XCTUnwrap(BitrateCalculator.outputSize(sourceWidth: 3000, sourceHeight: 2000))
        XCTAssertEqual(odd.height, 1080)
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertEqual(odd.width, 1620)
    }

    func testAlready1080pIsUnsupported() {
        XCTAssertNil(BitrateCalculator.outputSize(sourceWidth: 1920, sourceHeight: 1080))
        XCTAssertNil(BitrateCalculator.outputSize(sourceWidth: 1080, sourceHeight: 1920))
        XCTAssertNil(BitrateCalculator.plan(sourceWidth: 1280, sourceHeight: 720, frameRate: 30,
                                            isHDR: false, sourceVideoBitrate: 10_000_000))
    }

    // MARK: 原片碼率極低／極高

    func testVeryLowSourceBitrateCappedAt60Percent() throws {
        // 10 Mbps 的 4K30：複雜度觸底 0.8，下限 7 Mbps，但不能超過原片 60% → 6 Mbps
        let p = try plan(3840, 2160, fps: 30, source: 10_000_000)
        XCTAssertEqual(p.complexity, 0.8, accuracy: 1e-9)
        assertBitrate(p.targetBitrate, 6_000_000)
        XCTAssertLessThanOrEqual(Double(p.targetBitrate), 10_000_000 * 0.6 + 1)
    }

    func testLowSourceBitrateUsesFloor() throws {
        // 15 Mbps：算出來 6.97 Mbps，拉到下限 7 Mbps（仍低於原片 60% = 9 Mbps）
        let p = try plan(3840, 2160, fps: 30, source: 15_000_000)
        assertBitrate(p.targetBitrate, 7_000_000)
    }

    func testVeryHighSourceBitrateClampedComplexity() throws {
        // 300 Mbps 的高碼率原片：複雜度封頂 1.4，不會無限加碼
        let p = try plan(3840, 2160, fps: 30, source: 300_000_000)
        XCTAssertEqual(p.complexity, 1.4, accuracy: 1e-9)
        assertBitrate(p.targetBitrate, 1920 * 1080 * 30 * 0.14 * 1.4)
        XCTAssertLessThanOrEqual(Double(p.targetBitrate), BitrateCalculator.bounds(frameRate: 30, isHDR: false).upperBound)
    }

    func testTargetStaysWithinBoundsForCommonFrameRates() throws {
        // 原片碼率夠高（不受 60% 限制）時，各種影格率、SDR/HDR 都要落在上下限內
        for fps in [24.0, 25, 29.97, 30, 48, 50, 60, 120] {
            for hdr in [false, true] {
                let p = try plan(3840, 2160, fps: fps, hdr: hdr, source: 400_000_000)
                let bounds = BitrateCalculator.bounds(frameRate: fps, isHDR: hdr)
                XCTAssertGreaterThanOrEqual(Double(p.targetBitrate), bounds.lowerBound - 1, "\(fps) fps HDR=\(hdr)")
                XCTAssertLessThanOrEqual(Double(p.targetBitrate), bounds.upperBound + 1, "\(fps) fps HDR=\(hdr)")
                XCTAssertEqual(p.keyFrameInterval, Int((fps * 2).rounded()))
            }
        }
    }

    func testUnknownSourceBitrateUsesNeutralComplexity() throws {
        let p = try plan(3840, 2160, fps: 30, source: nil)
        XCTAssertEqual(p.complexity, 1)
        assertBitrate(p.targetBitrate, 1920 * 1080 * 30 * 0.14)
    }

    // MARK: 預估大小

    func testEstimatedFileSize() throws {
        let p = try plan(3840, 2160, fps: 30, source: 45_000_000)
        let size = BitrateCalculator.estimatedFileSize(plan: p, duration: 60, audioBitrate: 256_000)
        let expected = (Double(p.targetBitrate) + 256_000) * 60 / 8 * 1.01
        XCTAssertEqual(Double(size), expected, accuracy: 2)
    }
}

final class ISO6709Tests: XCTestCase {
    func testParsesLatitudeLongitudeAltitude() throws {
        let location = try XCTUnwrap(DownscaleSupport.parseISO6709("+25.0330+121.5654+010.000/"))
        XCTAssertEqual(location.coordinate.latitude, 25.033, accuracy: 1e-6)
        XCTAssertEqual(location.coordinate.longitude, 121.5654, accuracy: 1e-6)
        XCTAssertEqual(location.altitude, 10, accuracy: 1e-6)
    }

    func testParsesNegativeWithoutAltitude() throws {
        let location = try XCTUnwrap(DownscaleSupport.parseISO6709("-33.8688+151.2093/"))
        XCTAssertEqual(location.coordinate.latitude, -33.8688, accuracy: 1e-6)
        XCTAssertEqual(location.coordinate.longitude, 151.2093, accuracy: 1e-6)
    }

    func testRejectsGarbage() {
        XCTAssertNil(DownscaleSupport.parseISO6709("hello"))
        XCTAssertNil(DownscaleSupport.parseISO6709("+95.0+10.0/"))
    }
}
