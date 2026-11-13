/// One animated icon: its outline drawing, its solid drawing and the motion of the whole icon, in the 24×24 viewBox.
/// Every icon is a static member, `PulsoIcon.bell`, with its aliases (`PulsoIcon.gear`) and an `Icon`-suffixed name
/// (`PulsoIcon.bellIcon`), as the React package exports them; `PulsoIcon.byKey(_:)` finds one by its stored key.
public struct PulsoIcon: Sendable, Hashable, Identifiable {
    /// PascalCase name, e.g. `Bell`.
    public let name: String
    /// kebab-case key shared with every package (the npm packages' `names`), e.g. `bell`; what gets stored on items.
    public let key: String
    public let svg: IconMotion?
    public let nodes: [IconNode]
    /// The designed solid drawing, or the one pulsoicon-core `autoSolid` derived from the outline (computed when generating).
    public let solid: [IconNode]

    public var id: String { key }

    public init(_ name: String, _ key: String, svg: IconMotion? = nil, nodes: [IconNode], solid: [IconNode]) {
        self.name = name
        self.key = key
        self.svg = svg
        self.nodes = nodes
        self.solid = solid
    }

    /// Seconds until every part of the outline (or the solid) drawing has finished playing.
    public func duration(solid: Bool) -> Double {
        let parts: [Track] = solid
            ? self.solid.flatMap { node in node.motion?.tracks(filled: node.role == .fill && node.fill != false) ?? [] }
            : nodes.flatMap { $0.motion?.tracks(filled: false) ?? [] }
        return (parts + (svg?.tracks(filled: solid) ?? [])).map { $0.delay + $0.duration }.max() ?? 0
    }

    public static func == (lhs: PulsoIcon, rhs: PulsoIcon) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// One recipe on one shape (or on the whole icon): delay `d` in seconds, direction `x` / `y`, amplitude `a`,
/// pivot (`ox`, `oy`) in the 24×24 viewBox. Zero means "the recipe's default", exactly as in the React package.
public struct IconMotion: Sendable, Hashable {
    public let recipe: Recipe
    public let d: Double
    public let x: Double
    public let y: Double
    public let a: Double
    public let ox: Double
    public let oy: Double

    public init(_ recipe: Recipe, d: Double = 0, x: Double = 0, y: Double = 0, a: Double = 0, ox: Double = 12, oy: Double = 12) {
        self.recipe = recipe
        self.d = d
        self.x = x
        self.y = y
        self.a = a
        self.ox = ox
        self.oy = oy
    }

    /// The keyframes it plays; on a filled solid shape the stroke-drawing recipes pop in instead.
    func tracks(filled: Bool) -> [Track] {
        (filled ? recipe.solidFallback : recipe).tracks(d: d, x: x, y: y, a: a)
    }
}

/// Geometry of one shape in viewBox units.
public enum IconShape: Sendable, Hashable {
    /// SVG path data (`d`).
    case path(String)
    case circle(cx: Double, cy: Double, r: Double)
    case ellipse(cx: Double, cy: Double, rx: Double, ry: Double)
    case rect(x: Double, y: Double, width: Double, height: Double, rx: Double, ry: Double)
    case line(x1: Double, y1: Double, x2: Double, y2: Double)
    /// x, y pairs; `closed` for `<polygon>`.
    case poly(points: [Double], closed: Bool)
}

/// How a solid shape is drawn (pulsoicon-core `SolidRole`): filled, a stroke cut out of the fills, or a line cut out and drawn outside them.
public enum SolidRole: String, Sendable, Hashable {
    case fill, cut, line
}

/// One shape, as in the SVG: its own `fill` / `stroke` when set (nil = inherit from the group), a static
/// `stroke-dasharray`, a static `transform` as an SVG matrix (a b c d e f), and its optional motion.
public struct IconNode: Sendable, Hashable {
    public let shape: IconShape
    public let motion: IconMotion?
    public let fill: Bool?
    public let stroke: Bool?
    public let dash: [Double]?
    public let matrix: [Double]?
    public let role: SolidRole

    public init(_ shape: IconShape, motion: IconMotion? = nil, fill: Bool? = nil, stroke: Bool? = nil, dash: [Double]? = nil, matrix: [Double]? = nil, role: SolidRole = .fill) {
        self.shape = shape
        self.motion = motion
        self.fill = fill
        self.stroke = stroke
        self.dash = dash
        self.matrix = matrix
        self.role = role
    }

    // Builders used by the generated icon files (one per SVG tag).

    public static func path(_ d: String, motion: IconMotion? = nil, fill: Bool? = nil, stroke: Bool? = nil, dash: [Double]? = nil, matrix: [Double]? = nil, role: SolidRole = .fill) -> IconNode {
        IconNode(.path(d), motion: motion, fill: fill, stroke: stroke, dash: dash, matrix: matrix, role: role)
    }

    public static func circle(_ cx: Double, _ cy: Double, _ r: Double, motion: IconMotion? = nil, fill: Bool? = nil, stroke: Bool? = nil, dash: [Double]? = nil, matrix: [Double]? = nil, role: SolidRole = .fill) -> IconNode {
        IconNode(.circle(cx: cx, cy: cy, r: r), motion: motion, fill: fill, stroke: stroke, dash: dash, matrix: matrix, role: role)
    }

    public static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, motion: IconMotion? = nil, fill: Bool? = nil, stroke: Bool? = nil, dash: [Double]? = nil, matrix: [Double]? = nil, role: SolidRole = .fill) -> IconNode {
        IconNode(.ellipse(cx: cx, cy: cy, rx: rx, ry: ry), motion: motion, fill: fill, stroke: stroke, dash: dash, matrix: matrix, role: role)
    }

    public static func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, rx: Double = 0, ry: Double = 0, motion: IconMotion? = nil, fill: Bool? = nil, stroke: Bool? = nil, dash: [Double]? = nil, matrix: [Double]? = nil, role: SolidRole = .fill) -> IconNode {
        IconNode(.rect(x: x, y: y, width: width, height: height, rx: rx, ry: ry), motion: motion, fill: fill, stroke: stroke, dash: dash, matrix: matrix, role: role)
    }

    public static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, motion: IconMotion? = nil, fill: Bool? = nil, stroke: Bool? = nil, dash: [Double]? = nil, matrix: [Double]? = nil, role: SolidRole = .fill) -> IconNode {
        IconNode(.line(x1: x1, y1: y1, x2: x2, y2: y2), motion: motion, fill: fill, stroke: stroke, dash: dash, matrix: matrix, role: role)
    }

    public static func polyline(_ points: [Double], motion: IconMotion? = nil, fill: Bool? = nil, stroke: Bool? = nil, dash: [Double]? = nil, matrix: [Double]? = nil, role: SolidRole = .fill) -> IconNode {
        IconNode(.poly(points: points, closed: false), motion: motion, fill: fill, stroke: stroke, dash: dash, matrix: matrix, role: role)
    }

    public static func polygon(_ points: [Double], motion: IconMotion? = nil, fill: Bool? = nil, stroke: Bool? = nil, dash: [Double]? = nil, matrix: [Double]? = nil, role: SolidRole = .fill) -> IconNode {
        IconNode(.poly(points: points, closed: true), motion: motion, fill: fill, stroke: stroke, dash: dash, matrix: matrix, role: role)
    }
}
