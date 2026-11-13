import XCTest
@testable import Ledger

final class MagnetMathTests: XCTestCase {
    private let cal = MagnetCalibrationData(noise: 5, sides: [
        .top: Vec3(x: 0, y: 400, z: 50),
        .bottom: Vec3(x: 0, y: -60, z: 10),
        .left: Vec3(x: -300, y: 20, z: 0),
        .right: Vec3(x: 300, y: 20, z: 0),
    ])

    func testEstimateMatchesCalibratedSide() throws {
        let top = try XCTUnwrap(MagnetMath.estimate(Vec3(x: 0, y: 200, z: 25), calibration: cal))
        XCTAssertEqual(top.point.x, 0.5, accuracy: 0.05)
        XCTAssertLessThan(top.point.y, 0.2)

        let right = try XCTUnwrap(MagnetMath.estimate(Vec3(x: 150, y: 10, z: 0), calibration: cal))
        XCTAssertGreaterThan(right.point.x, 0.8)
    }

    func testEstimateRejectsUnknownDirection() {
        XCTAssertNil(MagnetMath.estimate(Vec3(x: 0, y: 0, z: 300), calibration: cal))
    }

    func testOffsetPointsTowardMagnetAndFadesWithDistance() {
        let near = MagnetMath.offset(frame: CGRect(x: 0, y: 100, width: 100, height: 50), magnet: CGPoint(x: 50, y: 0), pull: 1, force: 1)
        XCTAssertEqual(near.width, 0, accuracy: 0.001)
        XCTAssertLessThan(near.height, 0)

        let far = MagnetMath.offset(frame: CGRect(x: 0, y: 700, width: 100, height: 50), magnet: CGPoint(x: 50, y: 0), pull: 1, force: 1)
        XCTAssertLessThan(abs(far.height), abs(near.height))

        XCTAssertEqual(MagnetMath.offset(frame: .zero, magnet: nil, pull: 1, force: 1), .zero)
    }

    func testPresence() {
        XCTAssertEqual(MagnetMath.presence(2, noise: 5), 0)
        XCTAssertEqual(MagnetMath.presence(500, noise: 5), 1)
    }

    func testOrientationDriftIsNotAMagnet() {
        // 地磁 45 µT 轉了 30°：差 23 µT，但大小沒變
        XCTAssertTrue(MagnetMath.looksLikeOrientationDrift(delta: 23, fieldLength: 45.5, baseLength: 45))
        // 磁鐵：大小明顯變了
        XCTAssertFalse(MagnetMath.looksLikeOrientationDrift(delta: 60, fieldLength: 95, baseLength: 45))
        XCTAssertFalse(MagnetMath.looksLikeOrientationDrift(delta: 30, fieldLength: 54, baseLength: 45))
        // 變化比地磁轉 180° 還大，一定是磁鐵
        XCTAssertFalse(MagnetMath.looksLikeOrientationDrift(delta: 120, fieldLength: 45, baseLength: 45))
    }
}
