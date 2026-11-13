#if canImport(SwiftUI)
import SVGPath
import SwiftUI

/// Plays an icon from code, like the React package's ref: `startAnimation()` plays its motion and `stopAnimation()`
/// returns it to rest; both return when the motion has finished. Pass it to `PulsoIconView` as `handle`.
@MainActor
@Observable
public final class PulsoIconHandle {
    fileprivate var starts = 0
    fileprivate var stops = 0
    fileprivate var duration: Double = 0
    fileprivate var enabled = true

    public init() {}

    /// Plays the icon's motion (does nothing with Reduce Motion on, or when `animated` is false).
    public func startAnimation() async {
        guard enabled else { return }
        starts += 1
        try? await Task.sleep(for: .seconds(duration))
    }

    /// Returns to the resting frame.
    public func stopAnimation() async {
        guard enabled else { return }
        stops += 1
        try? await Task.sleep(for: .seconds(Double(releaseSeconds)))
    }
}

/// Draws `icon` at rest and plays its motion, with the React package's props and defaults: a 24×24 grid,
/// `strokeWidth` in grid units (constant in points with `absoluteStrokeWidth`), `solid` for the filled drawing,
/// round caps and joins, `color` defaulting to the foreground style (the React package's `currentColor`).
///
/// `animated` false keeps it still. `play` true plays the motion, false returns to rest. With `autoAnimated`
/// (default) a pointer hovering the icon plays it and leaving returns to rest (the React package plays on hover /
/// focus); a tap is the app's to decide, through `play` or `handle`. Nothing moves with Reduce Motion on.
public struct PulsoIconView: View {
    private let icon: PulsoIcon
    private let size: CGFloat
    private let color: Color?
    private let strokeWidth: CGFloat
    private let absoluteStrokeWidth: Bool
    private let solid: Bool
    private let animated: Bool
    private let autoAnimated: Bool
    private let play: Bool?
    private let handle: PulsoIconHandle?
    private let label: Text?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run = Run()

    public init(
        _ icon: PulsoIcon,
        size: CGFloat = 24,
        color: Color? = nil,
        strokeWidth: CGFloat = 2,
        absoluteStrokeWidth: Bool = false,
        solid: Bool = false,
        animated: Bool = true,
        autoAnimated: Bool = true,
        play: Bool? = nil,
        handle: PulsoIconHandle? = nil,
        label: Text? = nil
    ) {
        self.icon = icon
        self.size = size
        self.color = color
        self.strokeWidth = strokeWidth
        self.absoluteStrokeWidth = absoluteStrokeWidth
        self.solid = solid
        self.animated = animated
        self.autoAnimated = autoAnimated
        self.play = play
        self.handle = handle
        self.label = label
    }

    // The body is split into small functions: one long modifier chain is more than the type checker will solve in time.
    public var body: some View {
        let drawing = IconDrawing.of(icon, solid: solid)
        return lifecycle(triggers(accessible(canvas(drawing))), duration: drawing.duration)
    }

    private func canvas(_ drawing: IconDrawing) -> some View {
        let shading: GraphicsContext.Shading = color.map { .color($0) } ?? .foreground
        let strokeWidth = strokeWidth
        let absolute = absoluteStrokeWidth
        let solid = solid
        let svg = icon.svg
        let run = run
        let duration = drawing.duration
        return TimelineView(.animation(paused: run.startedAt == nil)) { timeline in
            let frame = run.frame(at: timeline.date, duration: duration)
            Canvas { context, canvas in
                let side = min(canvas.width, canvas.height)
                let stroke = absolute ? strokeWidth * 24 / side : strokeWidth
                context.scaleBy(x: side / 24, y: side / 24)
                let painter = Painter(shading: shading, stroke: stroke, frame: frame)
                painter.draw(drawing, svg: svg, solid: solid, in: &context)
            }
        }
        .frame(width: size, height: size)
    }

    private func accessible(_ content: some View) -> some View {
        content
            .accessibilityElement()
            .accessibilityLabel(label ?? Text(verbatim: ""))
            .accessibilityAddTraits(.isImage)
            .accessibilityHidden(label == nil)
    }

    /// What plays and stops the motion: hover, `play`, the handle.
    private func triggers(_ content: some View) -> some View {
        content
            .onHover { (inside: Bool) in
                guard animated, autoAnimated else { return }
                if inside { start() } else { stop() }
            }
            .onChange(of: play, initial: true) { (_: Bool?, play: Bool?) in
                guard animated, let play else { return }
                if play { start() } else { stop() }
            }
            .onChange(of: handle?.starts) { start() }
            .onChange(of: handle?.stops) { stop() }
    }

    /// Resets on a new icon or drawing, keeps the handle in sync, and returns to rest when a play ends.
    private func lifecycle(_ content: some View, duration: Double) -> some View {
        content
            .onChange(of: animated) { (_: Bool, animated: Bool) in
                if !animated { run = Run(token: run.token + 1) }
                sync(duration)
            }
            .onChange(of: icon) { run = Run(token: run.token + 1) }
            .onChange(of: solid) { run = Run(token: run.token + 1) }
            .onAppear { sync(duration) }
            .onChange(of: duration) { sync(duration) }
            .onChange(of: reduceMotion) { sync(duration) }
            .task(id: run.token) { await settle(token: run.token, duration: duration) }
    }

    private func sync(_ duration: Double) {
        handle?.duration = duration
        handle?.enabled = animated && !reduceMotion
    }

    private func start() {
        guard animated, !reduceMotion else { return }
        run = Run(startedAt: .now, token: run.token + 1)
    }

    private func stop() {
        guard animated, let started = run.startedAt, run.stoppedAt == nil else { return }
        let now = Date.now
        run = Run(startedAt: started, stoppedAt: now, frozen: now.timeIntervalSince(started), token: run.token + 1)
    }

    /// Back to rest (and the timeline paused) once the release has finished; a finished play stays on its last
    /// keyframe, which is the resting frame.
    private func settle(token: Int, duration: Double) async {
        guard let started = run.startedAt else { return }
        let end = run.stoppedAt.map { $0.addingTimeInterval(Double(releaseSeconds)) } ?? started.addingTimeInterval(duration)
        try? await Task.sleep(for: .seconds(max(end.timeIntervalSinceNow, 0)))
        if !Task.isCancelled, run.token == token { run = Run(token: token) }
    }
}

/// The current play: when it started, when it was stopped (the clock freezes at `frozen` seconds) and a token that
/// restarts the settle task.
private struct Run {
    var startedAt: Date?
    var stoppedAt: Date?
    var frozen: Double = 0
    var token = 0

    func frame(at now: Date, duration: Double) -> Frame {
        guard let startedAt else { return Frame(time: 0, release: 1) }
        if let stoppedAt {
            let progress = min(now.timeIntervalSince(stoppedAt) / Double(releaseSeconds), 1)
            return Frame(time: frozen, release: Curve.easeOut.value(at: progress))
        }
        return Frame(time: min(now.timeIntervalSince(startedAt), duration), release: 0)
    }
}

/// Where the animation is: play clock in seconds and how far it has eased back to rest (0 playing, 1 at rest).
private struct Frame {
    let time: Double
    let release: Double
}

extension Curve {
    func value(at progress: Double) -> Double {
        UnitCurve.bezier(startControlPoint: UnitPoint(x: x1, y: y1), endControlPoint: UnitPoint(x: x2, y: y2)).value(at: progress)
    }
}

extension Track {
    func value(at t: Double) -> Double {
        guard let segment = segment(at: t) else { return prop.rest }
        return segment.from + (segment.to - segment.from) * curve.value(at: segment.local)
    }
}

/// The value of `prop` in `tracks` at `frame`: the keyframe value, blended toward rest as the icon releases.
private func value(_ tracks: [Track], _ prop: Prop, _ frame: Frame) -> Double {
    guard let track = tracks.first(where: { $0.prop == prop }) else { return prop.rest }
    if frame.release >= 1 || (frame.release > 0 && track.snapBack) { return prop.rest }
    let live = track.value(at: frame.time)
    return live + (prop.rest - live) * frame.release
}

/// One drawing of an icon, prepared once: each shape's outline path and the keyframes it plays.
private struct IconDrawing {
    struct Part {
        let node: IconNode
        let path: Path
        let tracks: [Track]
    }

    let outline: [Part]
    let fills: [Part]
    let cuts: [Part]
    let lines: [Part]
    let svgTracks: [Track]
    let duration: Double

    @MainActor static var cache: [String: IconDrawing] = [:]

    @MainActor static func of(_ icon: PulsoIcon, solid: Bool) -> IconDrawing {
        let id = "\(icon.key)\(solid ? "#solid" : "")"
        if let drawing = cache[id] { return drawing }
        let part = { (node: IconNode, filled: Bool) in Part(node: node, path: path(node), tracks: node.motion?.tracks(filled: filled) ?? []) }
        let drawing = solid
            ? IconDrawing(
                outline: [],
                fills: icon.solid.filter { $0.role == .fill }.map { part($0, $0.fill != false) },
                cuts: icon.solid.filter { $0.role == .cut }.map { part($0, false) },
                lines: icon.solid.filter { $0.role == .line }.map { part($0, false) },
                svgTracks: icon.svg?.tracks(filled: true) ?? [],
                duration: icon.duration(solid: true)
            )
            : IconDrawing(outline: icon.nodes.map { part($0, false) }, fills: [], cuts: [], lines: [], svgTracks: icon.svg?.tracks(filled: false) ?? [], duration: icon.duration(solid: false))
        cache[id] = drawing
        return drawing
    }

    private static func path(_ node: IconNode) -> Path {
        switch node.shape {
        case let .path(d):
            do {
                // SVG 的 y 轴向下：SVGPath 默认翻转 y 轴（invertYAxis: true），不关掉整个图形会画到画布上方、看不见。
                return Path(try SVGPath(string: d, with: .init(invertYAxis: false)))
            } catch {
                assertionFailure("PulsoIcon: bad path data \(d): \(error)")
                return Path()
            }
        case let .circle(cx, cy, r):
            return Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        case let .ellipse(cx, cy, rx, ry):
            return Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        case let .rect(x, y, width, height, rx, ry):
            // SVG clamps each radius to half the side.
            let corner = CGSize(width: min(rx, width / 2), height: min(ry, height / 2))
            return Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerSize: corner, style: .circular)
        case let .line(x1, y1, x2, y2):
            return Path { $0.move(to: CGPoint(x: x1, y: y1)); $0.addLine(to: CGPoint(x: x2, y: y2)) }
        case let .poly(points, closed):
            return Path { p in
                p.move(to: CGPoint(x: points[0], y: points[1]))
                for i in stride(from: 2, to: points.count - 1, by: 2) {
                    p.addLine(to: CGPoint(x: points[i], y: points[i + 1]))
                }
                if closed { p.closeSubpath() }
            }
        }
    }
}

/// Inherited paint of a group, as on the SVG: whether its shapes fill and stroke unless they say otherwise.
private struct GroupPaint {
    let fill: Bool
    let stroke: Bool

    static let outline = GroupPaint(fill: false, stroke: true)
    static let filled = GroupPaint(fill: true, stroke: true)
    static let fillMask = GroupPaint(fill: true, stroke: false)
}

/// Draws a prepared drawing exactly as the React package's <svg>: outline, plain solid, or solid with its cuts and
/// lines masked against the fills.
private struct Painter {
    let shading: GraphicsContext.Shading
    let stroke: CGFloat
    let frame: Frame

    func draw(_ drawing: IconDrawing, svg: IconMotion?, solid: Bool, in context: inout GraphicsContext) {
        var root = context
        if let svg {
            let alpha = min(max(value(drawing.svgTracks, .opacity, frame), 0), 1)
            guard alpha > 0 else { return }
            root.opacity *= alpha
            apply(svg, drawing.svgTracks, to: &root)
        }
        if !solid {
            for part in drawing.outline { paint(part, .outline, shading, in: &root) }
        } else if drawing.cuts.isEmpty, drawing.lines.isEmpty {
            for part in drawing.fills { paint(part, .filled, shading, in: &root) }
        } else {
            // Fills with the cuts and lines cut out of them.
            root.drawLayer { layer in
                for part in drawing.fills { paint(part, .filled, shading, in: &layer) }
                layer.blendMode = .destinationOut
                for part in drawing.cuts + drawing.lines { paint(part, .outline, .color(.black), in: &layer) }
            }
            // Lines, hidden where they run inside the fills.
            root.drawLayer { layer in
                for part in drawing.lines { paint(part, .outline, shading, in: &layer) }
                layer.blendMode = .destinationOut
                for part in drawing.fills { paint(part, .fillMask, .color(.black), in: &layer) }
            }
        }
    }

    /// The motion transform as CSS builds it: translate, scale, rotate, skewY, about the pivot.
    private func apply(_ motion: IconMotion, _ tracks: [Track], to context: inout GraphicsContext) {
        let scale = value(tracks, .scale, frame)
        context.translateBy(x: value(tracks, .x, frame) + motion.ox, y: value(tracks, .y, frame) + motion.oy)
        context.scaleBy(x: scale * value(tracks, .scaleX, frame), y: scale * value(tracks, .scaleY, frame))
        context.rotate(by: .degrees(value(tracks, .rotate, frame)))
        let skew = value(tracks, .skewY, frame)
        if skew != 0 { context.concatenate(CGAffineTransform(a: 1, b: tan(skew * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)) }
        context.translateBy(x: -motion.ox, y: -motion.oy)
    }

    /// One shape: static transform, then its motion (opacity, path drawing, transform), painted as the group says unless it says otherwise.
    private func paint(_ part: IconDrawing.Part, _ group: GroupPaint, _ shading: GraphicsContext.Shading, in context: inout GraphicsContext) {
        let node = part.node
        let fill = node.fill ?? group.fill
        let strokeOn = node.stroke ?? group.stroke
        guard fill || strokeOn else { return }
        var shape = context
        if let m = node.matrix {
            shape.concatenate(CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]))
        }
        var path = part.path
        var drawsOn = false
        var length = 1.0
        if let motion = node.motion {
            let alpha = min(max(value(part.tracks, .opacity, frame), 0), 1)
            guard alpha > 0 else { return }
            shape.opacity *= alpha
            apply(motion, part.tracks, to: &shape)
            drawsOn = part.tracks.contains { $0.prop == .pathLength }
            if drawsOn {
                length = value(part.tracks, .pathLength, frame)
                let offset = value(part.tracks, .pathOffset, frame)
                if length < 1 || offset > 0 { path = path.trimmedPath(from: offset, to: min(offset + length, 1)) }
            }
        }
        if fill { shape.fill(path, with: shading) }
        if strokeOn, !drawsOn || length > 0 {
            // Drawing a stroke on replaces any dash of its own, as motion does on the web.
            let dash = drawsOn ? [] : (node.dash ?? []).map { CGFloat($0) }
            shape.stroke(path, with: shading, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round, dash: dash))
        }
    }
}
#endif
