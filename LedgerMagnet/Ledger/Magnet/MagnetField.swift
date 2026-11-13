import SwiftUI
import CoreMotion
import Observation

/// 磁力特別版的感測器：讀 iPhone 自己的磁力計，扣掉地磁，估計旁邊磁鐵的位置和吸力。
/// 全部在手機上算，不需要網路、不需要其他 App。
@MainActor
@Observable
final class MagnetField {
    static let shared = MagnetField()

    // MARK: 給畫面用（約 30 次／秒更新）

    /// 磁鐵在螢幕上的位置（點，全域座標）；沒把握時是 nil
    private(set) var point: CGPoint?
    /// 吸力 0…1
    private(set) var pull: Double = 0
    /// 有磁鐵的把握 0…1
    private(set) var presence: Double = 0
    /// 磁場變化量（µT）
    private(set) var strength: Double = 0
    /// 磁鐵太近，感測器飽和
    private(set) var tooClose = false
    private(set) var available = CMMotionManager().isMagnetometerAvailable

    var enabled: Bool = UserDefaults.standard.object(forKey: "magnet.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "magnet.enabled")
            enabled ? start() : stop()
        }
    }

    /// 吸力倍率 0.4…2
    var force: Double = UserDefaults.standard.object(forKey: "magnet.force") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(force, forKey: "magnet.force") }
    }

    private(set) var calibration: MagnetCalibrationData? = MagnetField.loadCalibration()
    var calibrated: Bool { calibration != nil }

    /// 螢幕大小（由最外層的光暈 overlay 回報）
    @ObservationIgnored var screenSize: CGSize = .zero

    // MARK: 校正用

    /// 每一筆讀數（約 50 次／秒），給校正畫面收集
    @ObservationIgnored var sampleSink: ((Vec3) -> Void)?

    // MARK: 內部

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var running = false
    /// 地磁（參考座標系，校正過的磁場）或基準線（裝置座標，未校正的原始磁場）
    @ObservationIgnored private var baseline: Vec3?
    @ObservationIgnored private var baselineIsRaw = false
    @ObservationIgnored private var smooth = Vec3.zero
    @ObservationIgnored private var lastPublish: TimeInterval = 0

    private init() {}

    func start() {
        guard enabled, !running, motion.isDeviceMotionAvailable else { return }
        running = true
        baseline = nil
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        motion.magnetometerUpdateInterval = 1.0 / 50.0
        motion.startMagnetometerUpdates()
        motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] dm, _ in
            guard let dm else { return }
            MainActor.assumeIsolated { self?.handle(dm) }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        motion.stopDeviceMotionUpdates()
        motion.stopMagnetometerUpdates()
        point = nil
        pull = 0
        presence = 0
        strength = 0
    }

    /// 重新量地磁（校正第一步、或手機換了地方）
    func resetBaseline() {
        baseline = nil
        smooth = .zero
    }

    func saveCalibration(_ c: MagnetCalibrationData?) {
        calibration = c
        if let c, let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: "magnet.calibration")
        } else {
            UserDefaults.standard.removeObject(forKey: "magnet.calibration")
        }
    }

    private static func loadCalibration() -> MagnetCalibrationData? {
        guard let data = UserDefaults.standard.data(forKey: "magnet.calibration") else { return nil }
        return try? JSONDecoder().decode(MagnetCalibrationData.self, from: data)
    }

    // MARK: 每一筆讀數

    private func handle(_ dm: CMDeviceMotion) {
        let r: CMRotationMatrix = dm.attitude.rotationMatrix
        let gravity = Vec3(x: dm.gravity.x, y: dm.gravity.y, z: dm.gravity.z)
        // CMRotationMatrix 的方向依文件不好確定：用重力自己對一次，選比較對的那個方向
        let down = Vec3(x: 0, y: 0, z: -1)
        let transposed: Bool = Self.mul(r, down, transposed: true).dot(gravity) > Self.mul(r, down, transposed: false).dot(gravity)

        let calibratedField: Bool = dm.magneticField.accuracy != .uncalibrated
        let field: Vec3
        if calibratedField {
            let f = dm.magneticField.field
            field = Vec3(x: f.x, y: f.y, z: f.z)
        } else if let raw = motion.magnetometerData?.magneticField {
            field = Vec3(x: raw.x, y: raw.y, z: raw.z)
        } else {
            return
        }
        let isRaw: Bool = !calibratedField

        // 校正過的磁場：地磁存在參考座標系，手機轉動也扣得掉。
        // 原始磁場含硬鐵偏差，只能在裝置座標當基準線。
        let inRef: Vec3 = isRaw ? field : Self.mul(r, field, transposed: !transposed)
        guard let base = baseline, baselineIsRaw == isRaw else {
            baseline = inRef
            baselineIsRaw = isRaw
            return
        }
        let expected: Vec3 = isRaw ? base : Self.mul(r, base, transposed: transposed)
        let delta: Vec3 = field - expected
        let mag: Double = delta.length

        let noise: Double = calibration?.noise ?? 6
        let quiet: Double = MagnetMath.threshold(noise: noise)
        // 沒磁鐵時慢慢跟著地磁走（換位置、系統重新校正）
        if mag < quiet {
            baseline = Vec3.lerp(base, inRef, isRaw ? 0.05 : 0.02)
        } else if isRaw {
            // 原始磁場：手機轉動時地磁也在變，轉得快就加快跟上
            let rr = dm.rotationRate
            let spin: Double = (rr.x * rr.x + rr.y * rr.y + rr.z * rr.z).squareRoot()
            if spin > 1.2, mag < 90 { baseline = Vec3.lerp(base, inRef, 0.2) }
        }

        smooth = Vec3.lerp(smooth, delta, 0.35)
        sampleSink?(delta)

        let now: TimeInterval = dm.timestamp
        guard now - lastPublish >= 1.0 / 30.0 else { return }
        lastPublish = now
        publish(field: field)
    }

    private func publish(field: Vec3) {
        let mag: Double = smooth.length
        let noise: Double = calibration?.noise ?? 6
        let p: Double = MagnetMath.presence(mag, noise: noise)
        var newPoint: CGPoint?
        var newPull: Double = 0
        if p > 0.05, let est = MagnetMath.estimate(smooth, calibration: calibration) {
            let lo: Double = MagnetMath.threshold(noise: noise)
            let x: Double = min(max((mag - lo) / max(est.fullStrength - lo, 1), 0), 1)
            newPull = pow(x, 0.7) * p
            if screenSize.width > 0 {
                newPoint = CGPoint(x: est.point.x * screenSize.width, y: est.point.y * screenSize.height)
            }
        }
        // 只有變化夠大才更新，減少畫面重算
        if abs(newPull - pull) > 0.01 || (newPull == 0) != (pull == 0) { pull = newPull }
        if Self.moved(point, newPoint) { point = newPoint }
        if abs(p - presence) > 0.02 || (p == 0) != (presence == 0) { presence = p }
        if abs(mag - strength) > 2 { strength = mag }
        let close: Bool = max(abs(field.x), abs(field.y), abs(field.z)) > 2400
        if close != tooClose { tooClose = close }
    }

    private static func moved(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case let (a?, b?): return abs(a.x - b.x) + abs(a.y - b.y) > 3
        default: return true
        }
    }

    private static func mul(_ m: CMRotationMatrix, _ v: Vec3, transposed: Bool) -> Vec3 {
        if transposed {
            return Vec3(x: m.m11 * v.x + m.m21 * v.y + m.m31 * v.z,
                        y: m.m12 * v.x + m.m22 * v.y + m.m32 * v.z,
                        z: m.m13 * v.x + m.m23 * v.y + m.m33 * v.z)
        }
        return Vec3(x: m.m11 * v.x + m.m12 * v.y + m.m13 * v.z,
                    y: m.m21 * v.x + m.m22 * v.y + m.m23 * v.z,
                    z: m.m31 * v.x + m.m32 * v.y + m.m33 * v.z)
    }
}
