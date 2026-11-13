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
    /// 地磁（參考座標系，校正過的磁場）
    @ObservationIgnored private var baseline: Vec3?
    @ObservationIgnored private var smooth = Vec3.zero
    @ObservationIgnored private var lastPublish: TimeInterval = 0
    @ObservationIgnored private var lastAccuracy: CMMagneticFieldCalibrationAccuracy?
    /// 旋轉矩陣的方向：裝置 = R × 參考（false）或 Rᵀ × 參考（true）。
    /// 只在手機夠斜、兩個方向分得出來時投票，之後固定，不會每一筆來回跳。
    @ObservationIgnored private var conventionVotes = 0
    /// 連續幾次都有把握（進場要連續幾次，避免一閃一閃）
    @ObservationIgnored private var confidentStreak = 0
    /// 同一個變化量維持多久（秒）；太久沒變多半是偏移，不是有人拿著磁鐵
    @ObservationIgnored private var steadySince: TimeInterval?
    @ObservationIgnored private var steadyRef = Vec3.zero

    /// 系統的磁力計還沒校準好（剛開機、附近有大型金屬）；這時不顯示磁鐵，避免亂飄
    private(set) var needsCompassCalibration = false

    private init() {}

    func start() {
        guard enabled, !running, motion.isDeviceMotionAvailable else { return }
        running = true
        resetBaseline()
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        motion.showsDeviceMovementDisplay = true
        motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] dm, _ in
            guard let dm else { return }
            MainActor.assumeIsolated { self?.handle(dm) }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        motion.stopDeviceMotionUpdates()
        clearOutput()
    }

    /// 重新量地磁（校正第一步、或手機換了地方）
    func resetBaseline() {
        baseline = nil
        smooth = .zero
        confidentStreak = 0
        steadySince = nil
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

    private func clearOutput() {
        if point != nil { point = nil }
        if pull != 0 { pull = 0 }
        if presence != 0 { presence = 0 }
        if strength != 0 { strength = 0 }
        if tooClose { tooClose = false }
    }

    // MARK: 每一筆讀數

    private func handle(_ dm: CMDeviceMotion) {
        let accuracy: CMMagneticFieldCalibrationAccuracy = dm.magneticField.accuracy
        // 系統重新校準時參考座標會跳，地磁要重量
        if accuracy != lastAccuracy {
            lastAccuracy = accuracy
            resetBaseline()
        }
        // 沒校準的磁場含手機本身的偏移，手機一轉就整個變，根本分不出磁鐵 → 先不顯示
        let uncalibrated: Bool = accuracy == .uncalibrated
        if uncalibrated != needsCompassCalibration { needsCompassCalibration = uncalibrated }
        guard !uncalibrated else {
            clearOutput()
            return
        }

        let r: CMRotationMatrix = dm.attitude.rotationMatrix
        let gravity = Vec3(x: dm.gravity.x, y: dm.gravity.y, z: dm.gravity.z)
        let down = Vec3(x: 0, y: 0, z: -1)
        let a: Double = Self.mul(r, down, transposed: false).dot(gravity)
        let b: Double = Self.mul(r, down, transposed: true).dot(gravity)
        // 手機平放時兩個方向算出來幾乎一樣，這時不投票
        if abs(a - b) > 0.3, abs(conventionVotes) < 20 { conventionVotes += b > a ? 1 : -1 }
        let transposed: Bool = conventionVotes > 0

        let f = dm.magneticField.field
        let field = Vec3(x: f.x, y: f.y, z: f.z)
        let inRef: Vec3 = Self.mul(r, field, transposed: !transposed)
        guard let base = baseline else {
            baseline = inRef
            return
        }
        let expected: Vec3 = Self.mul(r, base, transposed: transposed)
        var delta: Vec3 = field - expected
        let mag: Double = delta.length

        let noise: Double = calibration?.noise ?? 6
        let quiet: Double = MagnetMath.threshold(noise: noise)
        if mag < quiet {
            // 沒磁鐵時慢慢跟著地磁走（換位置、參考座標慢慢漂）
            baseline = Vec3.lerp(base, inRef, 0.02)
        } else if MagnetMath.looksLikeOrientationDrift(delta: mag, fieldLength: field.length, baseLength: base.length) {
            // 磁場大小沒變、只有方向不對 → 是手機姿態估計漂掉，不是磁鐵。快一點對回去
            baseline = Vec3.lerp(base, inRef, 0.15)
            delta = .zero
        }

        // 變化量很久都沒變：多半是殘留偏移（例如手機殼的磁環），慢慢吃進地磁
        let now: TimeInterval = dm.timestamp
        if mag >= quiet {
            if let since = steadySince, (delta - steadyRef).length < max(quiet * 0.5, 5) {
                if now - since > 20 { baseline = Vec3.lerp(baseline ?? base, inRef, 0.01) }
            } else {
                steadySince = now
                steadyRef = delta
            }
        } else {
            steadySince = nil
        }

        smooth = Vec3.lerp(smooth, delta, 0.35)
        sampleSink?(delta)

        guard now - lastPublish >= 1.0 / 30.0 else { return }
        lastPublish = now
        publish(field: field)
    }

    private func publish(field: Vec3) {
        let mag: Double = smooth.length
        let noise: Double = calibration?.noise ?? 6
        let p: Double = MagnetMath.presence(mag, noise: noise)
        // 進場要連續 4 次（約 0.13 秒）都有把握；已經在顯示時，降到很低才收起來
        let showing: Bool = point != nil
        if p > (showing ? 0.05 : 0.25) {
            confidentStreak += 1
        } else {
            confidentStreak = 0
        }
        var newPoint: CGPoint?
        var newPull: Double = 0
        if confidentStreak >= (showing ? 1 : 4), let est = MagnetMath.estimate(smooth, calibration: calibration) {
            let lo: Double = MagnetMath.threshold(noise: noise)
            let x: Double = min(max((mag - lo) / max(est.fullStrength - lo, 1), 0), 1)
            newPull = pow(x, 0.7) * p
            if screenSize.width > 0 {
                let target = CGPoint(x: est.point.x * screenSize.width, y: est.point.y * screenSize.height)
                // 位置也平滑一下，不要一跳一跳
                if let old = point {
                    newPoint = CGPoint(x: old.x + (target.x - old.x) * 0.35, y: old.y + (target.y - old.y) * 0.35)
                } else {
                    newPoint = target
                }
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
