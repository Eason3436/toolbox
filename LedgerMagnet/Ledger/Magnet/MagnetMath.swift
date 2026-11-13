import CoreGraphics
import Foundation

// 磁力特別版：純數學，沒有 UI、沒有感測器，方便單元測試

struct Vec3: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Vec3(x: 0, y: 0, z: 0)

    var length: Double { (x * x + y * y + z * z).squareRoot() }

    var normalized: Vec3 {
        let l: Double = length
        guard l > 1e-9 else { return .zero }
        return Vec3(x: x / l, y: y / l, z: z / l)
    }

    func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }

    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (a: Vec3, k: Double) -> Vec3 { Vec3(x: a.x * k, y: a.y * k, z: a.z * k) }

    /// a 往 b 靠近 t（0…1）
    static func lerp(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 { a + (b - a) * t }
}

/// 手機實體的四個邊（磁鐵放的位置；跟介面語系方向無關）
enum MagnetSide: String, CaseIterable, Codable, Sendable {
    case top, bottom, left, right

    /// 在螢幕上的位置（0…1，原點在螢幕左上角）
    var anchor: CGPoint {
        switch self {
        case .top: CGPoint(x: 0.5, y: 0)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .left: CGPoint(x: 0, y: 0.5)
        case .right: CGPoint(x: 1, y: 0.5)
        }
    }

    var title: String {
        switch self {
        case .top: "手機上緣"
        case .bottom: "手機下緣"
        case .left: "手機左側（音量鍵那側）"
        case .right: "手機右側（側邊按鈕那側）"
        }
    }
}

/// 校正結果：每支手機＋每顆磁鐵做一次
struct MagnetCalibrationData: Codable, Equatable, Sendable {
    /// 沒有磁鐵時的雜訊（µT）
    var noise: Double
    /// 磁鐵放在各邊時，磁場的變化量（裝置座標，µT）
    var sides: [MagnetSide: Vec3]
}

enum MagnetMath {
    /// 低於這個變化量就當作沒有磁鐵（µT）
    static func threshold(noise: Double) -> Double { max(noise * 2.5, 10) }

    /// 變化量其實只是手機姿態估計漂掉（地磁轉了個角度），不是磁鐵。
    /// 只是轉角度時磁場「大小」不會變；真的磁鐵幾乎一定會讓大小跟著變。
    static func looksLikeOrientationDrift(delta: Double, fieldLength: Double, baseLength: Double) -> Bool {
        guard baseLength > 1, delta < baseLength * 1.8 else { return false }
        let sizeChange: Double = abs(fieldLength - baseLength)
        return sizeChange < min(delta * 0.25, 8)
    }

    /// 有磁鐵的把握（0…1）
    static func presence(_ magnitude: Double, noise: Double) -> Double {
        let lo: Double = threshold(noise: noise)
        return smoothstep(lo, lo + 30, magnitude)
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t: Double = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 估計磁鐵在螢幕上的位置（0…1）與這個位置的「滿格」強度。看不出方向時回傳 nil。
    static func estimate(_ delta: Vec3, calibration: MagnetCalibrationData?) -> (point: CGPoint, fullStrength: Double)? {
        let mag: Double = delta.length
        guard mag > 1e-6 else { return nil }
        let u: Vec3 = delta.normalized

        guard let cal = calibration, !cal.sides.isEmpty else {
            return defaultEstimate(u, magnitude: mag)
        }

        var sumW: Double = 0
        var px: Double = 0
        var py: Double = 0
        var strength: Double = 0
        var best: Double = -1
        for (side, v) in cal.sides {
            let s: Double = u.dot(v.normalized)
            best = max(best, s)
            let c: Double = max(s, 0)
            let w: Double = c * c * c * c
            sumW += w
            px += w * Double(side.anchor.x)
            py += w * Double(side.anchor.y)
            strength += w * v.length
        }
        guard best > 0.55, sumW > 1e-6 else { return nil }
        return (CGPoint(x: px / sumW, y: py / sumW), max(strength / sumW, 30))
    }

    /// 沒校正：直接用裝置座標的 x（往右）、y（往上）當方向，推到螢幕邊緣
    private static func defaultEstimate(_ u: Vec3, magnitude: Double) -> (point: CGPoint, fullStrength: Double)? {
        let dx: Double = u.x
        let dy: Double = -u.y
        let planar: Double = (dx * dx + dy * dy).squareRoot()
        guard planar > 0.35 else { return nil }
        let m: Double = max(abs(dx), abs(dy))
        let p = CGPoint(x: 0.5 + 0.5 * dx / m, y: 0.5 + 0.5 * dy / m)
        return (p, 350)
    }

    /// 元素被吸過去的位移：越靠近磁鐵越多，最多 maxShift 點
    static func offset(frame: CGRect, magnet: CGPoint?, pull: Double, force: Double, maxShift: Double = 26) -> CGSize {
        guard let magnet, pull > 0.001, frame.width.isFinite, frame.height.isFinite else { return .zero }
        let vx: Double = Double(magnet.x - frame.midX)
        let vy: Double = Double(magnet.y - frame.midY)
        let d: Double = (vx * vx + vy * vy).squareRoot()
        guard d > 1 else { return .zero }
        let falloff: Double = exp(-d / 380)
        // 不會被吸過頭（最多走到距離的一半）
        let shift: Double = min(maxShift * force * pull * falloff, d * 0.5)
        return CGSize(width: vx / d * shift, height: vy / d * shift)
    }

    /// 被吸時稍微放大一點
    static func scale(frame: CGRect, magnet: CGPoint?, pull: Double, force: Double) -> Double {
        guard let magnet, pull > 0.001 else { return 1 }
        let vx: Double = Double(magnet.x - frame.midX)
        let vy: Double = Double(magnet.y - frame.midY)
        let d: Double = (vx * vx + vy * vy).squareRoot()
        return 1 + 0.035 * min(force, 1.5) * pull * exp(-d / 260)
    }
}
