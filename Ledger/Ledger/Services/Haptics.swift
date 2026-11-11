import CoreHaptics
import SwiftUI
import UIKit

/// 擬真觸覺回饋：用 Core Haptics 把動畫「刻」成震動節奏，跟畫面同步。
///
/// - 數字滾動：像機械計數器的齒輪，一開始密、越來越疏，最後「喀」一聲停住
/// - 圖示動畫：依 PulsoIcon 每個部件的動作配方（搖鈴、心跳、蓋章、彈跳…）自動產生
/// - 鍵盤、輸入錯誤、刪除、存檔吸進動態島各有自己的手感
///
/// 不支援 Core Haptics 的裝置（模擬器、iPad）什麼都不做；設定裡可以關掉。
/// 一下震動（還沒乘上使用者設定的強度）；duration 0 是「喀」一下，大於 0 是持續震動
struct HEvent {
    var t: Double
    var duration: Double
    var intensity: Float
    var sharpness: Float
}

/// 設定裡可以各自開關的震動種類
enum HapticKind: String, CaseIterable, Identifiable {
    case number, icon, keypad, save, delete, select, other
    var id: String { rawValue }
    var key: String { "haptic.\(rawValue)" }

    var label: String {
        switch self {
        case .number: "數字滾動"
        case .icon: "圖示動畫"
        case .keypad: "金額鍵盤"
        case .save: "記帳完成"
        case .delete: "刪除"
        case .select: "選取與切換"
        case .other: "其他"
        }
    }

    var detail: String {
        switch self {
        case .number: "金額滾動時一格一格地震"
        case .icon: "分類、膠囊圖示播動畫時"
        case .keypad: "按鍵、刪除、輸入錯誤"
        case .save: "卡片吸進動態島"
        case .delete: "刪除記帳、帳戶、資產等"
        case .select: "切換分頁、拖曳圖表、選日期"
        case .other: "隱藏金額、鍵盤收合、新增按鈕"
        }
    }

    var symbol: String {
        switch self {
        case .number: "textformat.123"
        case .icon: "sparkles"
        case .keypad: "circle.grid.3x3"
        case .save: "checkmark.circle"
        case .delete: "trash"
        case .select: "hand.tap"
        case .other: "ellipsis.circle"
        }
    }
}

final class Haptics {
    static let shared = Haptics()
    static let enabledKey = "hapticsEnabled"
    static let strengthKey = "hapticStrength"
    /// 強度倍率：1 是原始設計值；預設調高一點，比較有感
    static let defaultStrength = 1.6
    static let strengthRange: ClosedRange<Double> = 0.5...2.5

    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var lastPlayed: [String: CFTimeInterval] = [:]
    private var iconCache: [String: [HEvent]] = [:]

    private init() {}

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var strength: Float {
        Float(UserDefaults.standard.object(forKey: Self.strengthKey) as? Double ?? Self.defaultStrength)
    }

    func isOn(_ kind: HapticKind) -> Bool {
        UserDefaults.standard.object(forKey: kind.key) as? Bool ?? true
    }

    // MARK: 播放

    /// 播放一段節奏。`coalesce` 有值時，同一個 key 在 `window` 秒內只播一次（一頁好幾個數字同時滾動只震一次）
    func play(_ events: [HEvent], kind: HapticKind?, coalesce key: String? = nil, window: CFTimeInterval = 0.25) {
        guard supported, enabled, !events.isEmpty else { return }
        if let kind, !isOn(kind) { return }
        if let key {
            let now = CACurrentMediaTime()
            if let last = lastPlayed[key], now - last < window { return }
            lastPlayed[key] = now
        }
        guard let engine = prepareEngine() else { return }
        do {
            let gain = strength
            // 強度調高時尖銳度也稍微拉高，手感更清楚
            let edge: Float = gain > 1 ? min((gain - 1) * 0.12, 0.2) : 0
            let converted: [CHHapticEvent] = events.map { e in
                let params = [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: HapticShapes.clamp(e.intensity * gain)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: HapticShapes.clamp(e.sharpness + edge)),
                ]
                if e.duration > 0 {
                    return CHHapticEvent(eventType: .hapticContinuous, parameters: params, relativeTime: e.t, duration: e.duration)
                }
                return CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: e.t)
            }
            let pattern = try CHHapticPattern(events: converted, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // 引擎被系統停掉（例如來電）：下次重建
            self.engine = nil
        }
    }

    private func prepareEngine() -> CHHapticEngine? {
        if engine == nil {
            guard let e = try? CHHapticEngine() else { return nil }
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = true
            e.resetHandler = { [weak e] in try? e?.start() }
            e.stoppedHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.engine = nil }
            }
            engine = e
        }
        do { try engine?.start() } catch { engine = nil }
        return engine
    }

    // MARK: 常用的手感

    /// 數字滾動：齒輪一格一格轉過去，最後停住
    func numberRoll(from old: Double, to new: Double, duration: Double, coalesce: Bool = true) {
        guard old != new else { return }
        play(HapticShapes.roll(from: old, to: new, duration: duration), kind: .number, coalesce: coalesce ? "roll" : nil, window: 0.3)
    }

    /// 圖示動畫：跟著圖示自己的動作配方
    func icon(_ icon: PulsoIcon, size: CGFloat) {
        let scale = Float(min(max(size / 28, 0.55), 1))
        let key = "\(icon.key)@\(Int(scale * 20))"
        let events: [HEvent]
        if let cached = iconCache[key] {
            events = cached
        } else {
            events = HapticShapes.icon(icon, scale: scale)
            iconCache[key] = events
        }
        play(events, kind: .icon, coalesce: "icon", window: 0.12)
    }

    /// 沒有 PulsoIcon 的 SF Symbol 彈一下
    func symbolBounce(size: CGFloat) {
        let s = Float(min(max(size / 28, 0.55), 1))
        play([HapticShapes.tap(0, 0.6 * s, 0.6), HapticShapes.tap(0.16, 0.25 * s, 0.45)], kind: .icon, coalesce: "icon", window: 0.12)
    }

    func key(_ key: AmountInputLogic.Key) {
        switch key {
        case .digit: play([HapticShapes.tap(0, 0.55, 0.85), HapticShapes.tap(0.035, 0.18, 0.3)], kind: .keypad)
        case .decimal: play([HapticShapes.tap(0, 0.4, 1)], kind: .keypad)
        case .delete: play([HapticShapes.tap(0, 0.5, 0.3), HapticShapes.tap(0.04, 0.15, 0.2)], kind: .keypad)
        }
    }

    /// 輸入無效：跟著數字左右抖三下（0.3 秒）
    func reject() {
        var events: [HEvent] = []
        for k in 0..<6 {
            let t = Double(2 * k + 1) / 12 * 0.3
            events.append(HapticShapes.tap(t, Float(0.75 - Double(k) * 0.08), 0.45))
        }
        play(events, kind: .keypad)
    }

    /// 隱藏／顯示金額：像快門
    func shutter() {
        play([HapticShapes.tap(0, 0.55, 0.95), HapticShapes.tap(0.06, 0.3, 0.5)], kind: .other, coalesce: "shutter", window: 0.4)
    }

    /// 刪除：紙揉成一團丟掉
    func trash() {
        var events = HapticShapes.grain(0, 0.16, 0.4, 0.65, interval: 0.025)
        events.append(HapticShapes.tap(0.2, 0.75, 0.2))
        play(events, kind: .delete, coalesce: "trash", window: 0.4)
    }

    /// 鍵盤滑上來／收下去
    func slide(up: Bool) {
        var events = HapticShapes.swell(0, 0.22, peak: 0.22, sharpness: 0.2, steps: 5) { u in up ? u : 1 - u }
        events.append(HapticShapes.tap(0.22, 0.3, 0.5))
        play(events, kind: .other, coalesce: "slide", window: 0.2)
    }

    /// 選取、切換（分頁、圖表拖曳、日期）
    func selection() {
        play([HapticShapes.tap(0, 0.45, 0.75)], kind: .select, coalesce: "select", window: 0.03)
    }

    /// 按下按鈕：壓下去再彈起來
    func press() {
        play([HapticShapes.tap(0, 0.7, 0.5), HapticShapes.tap(0.09, 0.3, 0.4)], kind: .other)
    }

    /// 設定頁試震：不看各項開關（只看總開關）
    func sample(_ kind: HapticKind?) {
        let events: [HEvent]
        switch kind {
        case .number, nil: events = HapticShapes.roll(from: 0, to: 12_345, duration: 0.6)
        case .icon: events = HapticShapes.icon(.bellRing, scale: 1)
        case .keypad: events = [HapticShapes.tap(0, 0.55, 0.85), HapticShapes.tap(0.035, 0.18, 0.3),
                                HapticShapes.tap(0.16, 0.55, 0.85), HapticShapes.tap(0.195, 0.18, 0.3)]
        case .save: islandSuck(); return
        case .delete:
            events = HapticShapes.grain(0, 0.16, 0.4, 0.65, interval: 0.025) + [HapticShapes.tap(0.2, 0.75, 0.2)]
        case .select: events = [HapticShapes.tap(0, 0.45, 0.75), HapticShapes.tap(0.12, 0.45, 0.75)]
        case .other: events = [HapticShapes.tap(0, 0.55, 0.95), HapticShapes.tap(0.06, 0.3, 0.5)]
        }
        play(events, kind: nil)
    }

    /// 記一筆存檔：卡片咻地吸進動態島、撞進去、島上打勾
    /// 時間對應 IslandSuckView 的動畫（飛 0.06–0.36s、進島約 0.48s、展開約 0.58s）
    func islandSuck() {
        var events = HapticShapes.swell(0.06, 0.32, peak: 0.55, sharpness: 0.2, steps: 8) { u in u * u }
        events.append(HapticShapes.tap(0.4, 0.9, 0.35))
        events.append(HapticShapes.tap(0.5, 0.3, 0.5))
        events.append(HapticShapes.tap(0.6, 0.55, 0.6))
        events.append(HapticShapes.tap(0.72, 0.85, 0.85))
        play(events, kind: .save)
    }
}

// MARK: - 節奏產生

enum HapticShapes {
    static func tap(_ t: Double, _ intensity: Float, _ sharpness: Float) -> HEvent {
        HEvent(t: max(t, 0), duration: 0, intensity: intensity, sharpness: clamp(sharpness))
    }

    static func buzz(_ t: Double, _ duration: Double, _ intensity: Float, _ sharpness: Float) -> HEvent {
        HEvent(t: max(t, 0), duration: max(duration, 0.01), intensity: intensity, sharpness: clamp(sharpness))
    }

    /// 連續震動，強度依 `shape(0…1)` 變化（切成幾段接起來）
    static func swell(_ t: Double, _ duration: Double, peak: Float, sharpness: Float, steps: Int = 6,
                      shape: (Double) -> Double) -> [HEvent] {
        let seg = duration / Double(steps)
        return (0..<steps).compactMap { i in
            let u = (Double(i) + 0.5) / Double(steps)
            let v = peak * Float(max(shape(u), 0))
            return v < 0.02 ? nil : buzz(t + Double(i) * seg, seg, v, sharpness)
        }
    }

    /// 細碎的顆粒感（筆在紙上畫、紙揉皺、輪子滾）
    static func grain(_ t: Double, _ duration: Double, _ intensity: Float, _ sharpness: Float,
                      interval: Double = 0.035) -> [HEvent] {
        var events: [HEvent] = []
        var i = 0
        var x = 0.0
        while x < duration {
            let n = noise(i)
            events.append(tap(t + x, intensity * Float(0.6 + 0.4 * n), sharpness * Float(0.85 + 0.15 * noise(i + 7))))
            x += interval * (0.75 + 0.5 * noise(i + 3))
            i += 1
        }
        return events
    }

    private static func noise(_ i: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + 78.233) * 43758.5453
        return x - x.rounded(.down)
    }

    static func clamp(_ v: Float) -> Float { min(max(v, 0), 1) }

    // MARK: 數字滾動

    static func roll(from old: Double, to new: Double, duration: Double) -> [HEvent] {
        let delta = abs(new - old)
        let digits = max(1, Int(log10(max(delta, 1))) + 1)
        let ticks = min(3 + digits * 2, 14)
        let up = new > old
        var events: [HEvent] = []
        // .snappy 大致是 ease-out：前面轉得快、後面慢；每過一格進度就「喀」一下
        for i in 1..<ticks {
            let p = Double(i) / Double(ticks)
            let t = duration * (1 - pow(1 - p, 1.0 / 3.0))
            let fade = Float(1 - p * 0.55)
            events.append(tap(t * 0.92, 0.38 * fade, up ? 0.9 : 0.75))
        }
        // 停住
        events.append(tap(duration * 0.95, 0.6, up ? 0.6 : 0.45))
        return events
    }

    // MARK: 圖示動畫

    static func icon(_ icon: PulsoIcon, scale: Float) -> [HEvent] {
        var motions: [IconMotion] = []
        if let svg = icon.svg { motions.append(svg) }
        motions += icon.nodes.compactMap(\.motion)
        // 好幾個部件做同一個動作只算一次
        var seen = Set<String>()
        let unique = motions.filter { seen.insert("\($0.recipe.rawValue)@\(Int($0.d * 100))").inserted }.prefix(4)
        let each = scale / Float(max(1, unique.count)).squareRoot()
        return unique.flatMap { recipe($0.recipe, at: $0.d, k: each) }
    }

    /// 每個動作配方的手感；時間點對應 Recipe.swift 的關鍵影格
    static func recipe(_ r: Recipe, at d: Double, k: Float) -> [HEvent] {
        func T(_ t: Double, _ i: Float, _ s: Float) -> HEvent { tap(d + t, i * k, s) }
        func S(_ t: Double, _ dur: Double, _ i: Float, _ s: Float, _ shape: (Double) -> Double) -> [HEvent] {
            swell(d + t, dur, peak: i * k, sharpness: s, shape: shape)
        }
        func G(_ t: Double, _ dur: Double, _ i: Float, _ s: Float, _ every: Double = 0.035) -> [HEvent] {
            grain(d + t, dur, i * k, s, interval: every)
        }
        // 依序幾下：第 n 下在 at(n) 秒，強度乘上 amps[n]
        func seq(_ amps: [Float], _ at: (Int) -> Double, _ i: Float, _ s: Float) -> [HEvent] {
            var out: [HEvent] = []
            for n in amps.indices { out.append(T(at(n), i * amps[n], s)) }
            return out
        }
        let hump: (Double) -> Double = { sin(.pi * $0) }
        let rise: (Double) -> Double = { $0 }
        let decay: (Double) -> Double = { 1 - $0 }

        switch r {
        case .draw, .drawBack, .drawOut:
            // 筆畫過紙面，最後提筆
            return G(0, 0.5, 0.22, 0.75) + [T(0.55, 0.25, 0.5)]
        case .redraw:
            return G(0, 0.7, 0.2, 0.7)
        case .pop:
            return [T(0.2, 0.7, 0.75), T(0.33, 0.25, 0.4)]
        case .press:
            return [T(0.13, 0.75, 0.35), T(0.27, 0.3, 0.6)]
        case .spin:
            return S(0, 0.8, 0.35, 0.25, hump) + G(0, 0.8, 0.18, 0.9, 0.06)
        case .turn:
            return S(0, 0.35, 0.25, 0.3, rise) + [T(0.35, 0.5, 0.6), T(0.7, 0.35, 0.5)]
        case .ring:
            // 鈴鐺左右敲，越來越小，加一點餘震
            return seq([1, 0.85, 0.55, 0.3], { Double($0 + 1) / 6 * 0.7 }, 0.8, 0.95)
                + S(0.1, 0.6, 0.22, 0.95, decay)
        case .beat:
            // 撲通、撲通
            return [T(0.16, 0.9, 0.15), T(0.49, 0.6, 0.15)] + S(0.1, 0.5, 0.15, 0.05, hump)
        case .pulse:
            return S(0, 0.6, 0.35, 0.1, hump)
        case .slide:
            return S(0, 0.25, 0.25, 0.2, rise) + [T(0.25, 0.3, 0.5)] + S(0.25, 0.25, 0.15, 0.2, decay) + [T(0.5, 0.25, 0.6)]
        case .shoot:
            return S(0, 0.24, 0.4, 0.5, rise) + [T(0.24, 0.6, 0.9), T(0.6, 0.35, 0.5)]
        case .bounce:
            return [T(0.3, 0.75, 0.45), T(0.6, 0.4, 0.45)]
        case .shake:
            return seq([1, 1, 0.75, 0.75], { Double($0 + 1) / 5 * 0.5 }, 0.55, 0.8)
        case .tilt:
            return seq([1, 0.6, 0.3], { Double($0 + 1) / 4 * 0.7 }, 0.45, 0.4)
        case .swing:
            return seq([1, 0.75, 0.4], { Double($0 + 1) / 4 * 0.8 }, 0.45, 0.35)
                + S(0, 0.8, 0.12, 0.2, decay)
        case .sway:
            return seq([1, 1, 0.5], { Double($0 + 1) / 4 }, 0.3, 0.2)
        case .wobble:
            return [T(0.2, 0.4, 0.3), T(0.4, 0.4, 0.3)] + S(0, 0.6, 0.15, 0.15, hump)
        case .lift:
            return S(0, 0.28, 0.3, 0.3, rise) + [T(0.55, 0.4, 0.5)]
        case .blink:
            return [T(0.17, 0.3, 0.7)]
        case .flip, .fold:
            // 翻牌：翻過去的瞬間「啪」
            return S(0, 0.6, 0.3, 0.4, hump) + [T(0.3, 0.45, 0.8)]
        case .open:
            return G(0, 0.6, 0.18, 0.5, 0.05) + [T(0.3, 0.35, 0.6)]
        case .fade:
            return S(0, 0.5, 0.15, 0.1, hump)
        case .twinkle:
            // 閃一閃：細又亮的幾下
            return [T(0.12, 0.35, 1), T(0.3, 0.45, 1), T(0.47, 0.3, 1)]
        case .float:
            return S(0, 0.6, 0.2, 0.1, hump)
        case .grow, .growX:
            return S(0, 0.45, 0.35, 0.4, rise) + [T(0.45, 0.4, 0.6)]
        case .drop:
            // 掉下來「咚」，再小彈一下
            return S(0, 0.22, 0.2, 0.3, rise) + [T(0.24, 0.85, 0.3), T(0.38, 0.3, 0.4)]
        case .rise:
            return S(0, 0.5, 0.3, 0.3, decay)
        case .stamp:
            // 蓋章：重重一下
            return [T(0.22, 1, 0.15), T(0.34, 0.3, 0.4)] + S(0.22, 0.08, 0.5, 0.1, decay)
        case .jelly:
            return S(0, 0.7, 0.4, 0.05) { u in abs(sin(4 * .pi * u)) * (1 - u) }
        case .roll:
            return G(0, 0.8, 0.3, 0.35, 0.05) + S(0, 0.8, 0.2, 0.2, hump) + [T(0.8, 0.4, 0.5)]
        case .flicker:
            return [T(0.12, 0.4, 1), T(0.24, 0.2, 1), T(0.36, 0.35, 1)]
        }
    }
}

extension View {
    /// 取代 `.sensoryFeedback(.selection, trigger:)`：受設定裡的強度與「選取與切換」開關控制
    func selectionHaptic<T: Equatable>(trigger: T) -> some View {
        onChange(of: trigger) { Haptics.shared.selection() }
    }
}
