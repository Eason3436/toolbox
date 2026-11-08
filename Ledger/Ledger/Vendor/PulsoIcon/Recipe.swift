/// Animatable properties of a shape (or of the whole icon).
enum Prop: String, Sendable, Hashable, CaseIterable {
    case pathLength, pathOffset, opacity, x, y, rotate, scale, scaleX, scaleY, skewY

    var rest: Double {
        switch self {
        case .pathLength, .opacity, .scale, .scaleX, .scaleY: 1
        case .pathOffset, .x, .y, .rotate, .skewY: 0
        }
    }
}

/// Timing curve of one keyframe segment: a CSS cubic-bezier (motion's `easeInOut` / `easeOut` are the standard ones).
struct Curve: Sendable, Hashable {
    let x1: Double, y1: Double, x2: Double, y2: Double

    static let easeInOut = Curve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    static let easeOut = Curve(x1: 0, y1: 0, x2: 0.58, y2: 1)
    static let overshoot = Curve(x1: 0.34, y1: 1.56, x2: 0.64, y2: 1)
    static let softOut = Curve(x1: 0.22, y1: 1, x2: 0.36, y2: 1)
}

/// Keyframes of one property: `values` spread over `duration` seconds after `delay` (evenly, or at `times`),
/// each segment eased with `curve`. Before the delay the property rests; after the end it holds the last value.
struct Track: Sendable, Hashable {
    let prop: Prop
    let values: [Double]
    let delay: Double
    let duration: Double
    var curve: Curve = .easeInOut
    var times: [Double]? = nil
    /// Jump back to rest when stopped mid-play instead of easing back (spin).
    var snapBack = false

    /// The segment `progress` (0…1 of the play) falls in and how far through it, before easing.
    func segment(at t: Double) -> (from: Double, to: Double, local: Double)? {
        if t < delay { return nil }
        let progress = min(max((t - delay) / duration, 0), 1)
        let stops = times ?? values.indices.map { Double($0) / Double(values.count - 1) }
        var i = 1
        while i < stops.count - 1, progress > stops[i] { i += 1 }
        let span = stops[i] - stops[i - 1]
        let local = span <= 0 ? 1 : min(max((progress - stops[i - 1]) / span, 0), 1)
        return (values[i - 1], values[i], local)
    }
}

/// Seconds the parts take to settle back when an animation is stopped mid-play.
let releaseSeconds = 0.25

private func or(_ value: Double, _ fallback: Double) -> Double { value != 0 ? value : fallback }

/// Motion vocabulary, ported 1:1 from pulsoicon-core `recipes.ts` (same keyframes, durations, easings; checked against
/// it by the tests) and identical to the Kotlin `Recipe.kt`. Translations are viewBox units, angles degrees, delays seconds.
public enum Recipe: String, Sendable, CaseIterable {
    case draw, redraw, pop, press, spin, turn, ring, beat, pulse, slide, shoot, bounce, shake, tilt, swing, lift
    case blink, flip, open, fold, fade, twinkle, float, grow, drop, rise, stamp, jelly, roll, sway, flicker, wobble, growX
    case drawBack, drawOut

    /// Stroke-drawing recipes have nothing to draw on a filled shape, so solid shapes pop in instead.
    var solidFallback: Recipe {
        switch self {
        case .draw, .drawBack, .drawOut, .redraw: .pop
        default: self
        }
    }

    func tracks(d: Double, x: Double, y: Double, a: Double) -> [Track] {
        func t(_ prop: Prop, _ duration: Double, _ values: Double..., curve: Curve = .easeInOut, times: [Double]? = nil) -> Track {
            Track(prop: prop, values: values, delay: d, duration: duration, curve: curve, times: times)
        }
        // The quick fade-in of a stroke that draws on.
        let fadeIn = Track(prop: .opacity, values: [0, 1], delay: d, duration: 0.1)
        switch self {
        case .draw:
            return [t(.pathLength, 0.55, 0, 1), fadeIn]
        case .drawBack:
            return [t(.pathLength, 0.55, 0, 1), t(.pathOffset, 0.55, 1, 0), fadeIn]
        case .drawOut:
            return [t(.pathLength, 0.55, 0, 1), t(.pathOffset, 0.55, 0.5, 0), fadeIn]
        case .redraw:
            return [t(.pathLength, 0.7, 1, 0, 1), t(.pathOffset, 0.7, 0, 1, 0)]
        case .pop:
            return [t(.scale, 0.45, 0, 1 + or(a, 0.25), 1), t(.opacity, 0.45, 0, 1, 1)]
        case .press:
            return [t(.scale, 0.4, 1, 1 - or(a, 0.15), 1.05, 1)]
        case .spin:
            return [Track(prop: .rotate, values: [0, or(a, 360)], delay: d, duration: 0.8, snapBack: true)]
        case .turn:
            return [t(.rotate, 0.7, 0, or(a, 90), 0)]
        case .ring:
            let v = or(a, 14)
            return [t(.rotate, 0.7, 0, -v, v * 0.85, -v * 0.55, v * 0.3, 0)]
        case .beat:
            let v = or(a, 0.16)
            return [t(.scale, 0.65, 1, 1 + v, 1 - v * 0.3, 1 + v * 0.6, 1)]
        case .pulse:
            return [t(.scale, 0.6, 1, 1 + or(a, 0.08), 1)]
        case .slide:
            let v = or(a, 2.5)
            return [t(.x, 0.5, 0, x * v, 0), t(.y, 0.5, 0, y * v, 0)]
        case .shoot:
            let v = or(a, 7)
            let times = [0, 0.4, 0.41, 1.0]
            return [
                t(.x, 0.6, 0, x * v, -x * v, 0, times: times),
                t(.y, 0.6, 0, y * v, -y * v, 0, times: times),
                t(.opacity, 0.6, 1, 0, 0, 1, times: times),
            ]
        case .bounce:
            let v = or(a, 3)
            return [t(.x, 0.6, 0, x * v, 0, x * v * 0.4, 0), t(.y, 0.6, 0, y * v, 0, y * v * 0.4, 0)]
        case .shake:
            let v = or(a, 1.5)
            return [t(.x, 0.5, 0, -v, v, -v * 0.6, v * 0.6, 0)]
        case .tilt:
            let v = or(a, 12)
            return [t(.rotate, 0.7, 0, -v, v * 0.6, -v * 0.3, 0)]
        case .swing:
            let v = or(a, 10)
            return [t(.rotate, 0.8, 0, v, -v * 0.75, v * 0.4, 0)]
        case .lift:
            return [t(.x, 0.55, 0, x * 2.5, 0), t(.y, 0.55, 0, or(y, -1) * 2.5, 0), t(.rotate, 0.55, 0, a, 0)]
        case .blink:
            return [t(.scaleY, 0.35, 1, 0.1, 1)]
        case .flip:
            return [t(.scaleX, 0.6, 1, -1, 1)]
        case .open:
            return [t(.scaleX, 0.6, 1, 1 - or(a, 0.35), 1), t(.skewY, 0.6, 0, -or(y, 6), 0)]
        case .fold:
            return [t(.scaleY, 0.6, 1, -1, 1)]
        case .fade:
            return [t(.opacity, 0.5, 1, 0.15, 1)]
        case .twinkle:
            let v = or(a, 18)
            return [t(.rotate, 0.7, 0, -v, v, 0), t(.scale, 0.7, 1, 0.85, 1.1, 1)]
        case .float:
            return [t(.y, 0.6, 0, -or(a, 1.5), 0)]
        case .grow:
            return [t(.scaleY, 0.45, 0, 1)]
        case .growX:
            return [t(.scaleX, 0.45, 0, 1)]
        case .drop:
            let v = or(a, 6)
            return [
                t(.x, 0.45, x * v, 0, curve: .overshoot),
                t(.y, 0.45, or(y, -1) * v, 0, curve: .overshoot),
                t(.opacity, 0.45, 0, 1, curve: .overshoot),
            ]
        case .rise:
            return [t(.y, 0.5, or(a, 3), 0, curve: .softOut), t(.opacity, 0.5, 0, 1, curve: .softOut)]
        case .stamp:
            return [t(.scale, 0.45, 1 + or(a, 0.6), 0.92, 1), t(.opacity, 0.45, 0, 1, 1)]
        case .jelly:
            let v = or(a, 0.18)
            return [
                t(.scaleX, 0.7, 1, 1 + v, 1 - v * 0.6, 1 + v * 0.3, 1),
                t(.scaleY, 0.7, 1, 1 - v, 1 + v * 0.6, 1 - v * 0.3, 1),
            ]
        case .roll:
            let v = or(a, 3)
            let dir = or(x, 1)
            return [t(.x, 0.8, 0, dir * v, 0), t(.rotate, 0.8, 0, dir * 180, 360 * dir)]
        case .sway:
            let v = or(a, 6)
            return [t(.rotate, 1, 0, v, -v, v * 0.5, 0)]
        case .flicker:
            return [t(.opacity, 0.6, 1, 0.3, 1, 0.5, 1, times: [0, 0.2, 0.4, 0.6, 1])]
        case .wobble:
            let v = or(a, 8)
            return [t(.rotate, 0.6, 0, -v, v, 0), t(.scale, 0.6, 1, 1.08, 1.08, 1)]
        }
    }
}
