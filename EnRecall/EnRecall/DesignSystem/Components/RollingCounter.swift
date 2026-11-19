import SwiftUI
import QuartzCore

// 滾動計數器：減號、數字、加號，數字像里程表一樣滾動。
// 移植自 Bencho 的「Rolling counter」（MIT，bencho.dev/licence），原本是 React + CSS，
// 這裡改寫成 SwiftUI：lucide 的圖示換成 SF Symbols，CSS 變數換成 App 自己的顏色，
// 物理參數和註解照搬（註解說明那些數字為什麼是那樣）。
//
// Bencho 的設計 token 對應到這個 App：
//   --card       → Color.er.surface（slab 沒指定時的底色）
//   --fill-slab  → Color.er.surfaceMuted（卡片裡凹下去的一塊）
//   --fill-on    → Color.er.text
//   --ink        → Color.er.text
//   --pane-edge  → Color.er.outline
//   --signal     → Color.er.primary（網頁版的鍵盤焦點框；iOS 用系統的焦點效果，不另外畫）
//   --font-ui    → 系統字（SF Pro），等寬數字
// 按鍵的底色原本是 color-mix(ink 6%, slab)，按下 10%：對應 Color.er.fill／Color.er.outline，
// 兩組顏色在淺色、深色都剛好是 slab 往文字色推一點。

/* ══ Rolling counter ══════════════════════════════════════
   A number between a minus and a plus. Every digit is a strip
   of 0–9 behind a window, and changing the number rolls the
   strips to their new digits like an odometer.

   ── EACH COLUMN COUNTS, IT DOES NOT SHOW ───────────────
   A column's target is not its digit but the number of whole
   tens, hundreds… in the value: 1284 is 1284 for the ones
   column, 128 for the tens, 12 for the hundreds. So 9 → 10 is
   the ones column moving FORWARD one more step (9 → 0) and the
   tens moving forward one — never a strip running back down
   through eight digits to reach zero. The strip is 0–9 and a
   second 0, and where it sits is the count taken round ten.

   ── ONE SPRING PER COLUMN, AND THEY GO IN TURN ─────────
   A change reaches the ones first and each column to the left
   a little later — Stagger — so a carry reads as a carry,
   rippling up the number, rather than the whole row jumping.

   ── THREE WAYS TO CHANGE IT ────────────────────────────
   Press a button for one step; hold it and it repeats, faster
   and in bigger steps the longer you hold. Or take the number
   itself and drag it up or down, a step every few pixels; let
   go while it is moving and it keeps rolling and runs down. */

/* ── one spring, for everything that settles ───────────────
   Frames, not milliseconds. `dt` is expressed in sixtieths of
   a second and the damping is RAISED to it rather than
   multiplied by it, so a dropped frame decays the same amount
   of energy as the two frames it replaced. Multiplying is the
   version that makes a spring behave differently on a busy
   page, which is the hardest kind of bug to see.
   （iPhone 的 ProMotion 是 120Hz，dt 就是 0.5，同一個道理。）

   The loop parks itself the moment the value has settled.
   沒在動的時候不留 CADisplayLink。 */

/* 0..100 into the two numbers a spring actually has.

   Both ends have to be usable, which is what fixes the range:
   at 0 it is slow and heavy and still arrives, at 100 it is
   quick with a visible overshoot, and nowhere in between does
   it ring for longer than it takes to read. */
/* The pair is chosen by DAMPING RATIO and then written back
   as stiffness and decay, because the ratio is the thing a
   person is actually setting and the two numbers on their own
   do not say what they add up to.

     zeta = -ln(d) / (2 * sqrt(k))

   The first version of this ran 0.06..0.26 stiffness against
   0.93..0.74 decay, which reads as a sensible spread and is
   not one: it puts zeta between 0.15 and 0.16 across the
   WHOLE range, so every setting overshot by about sixty per
   cent and the knob only changed how fast it did it.

     0   → zeta ~0.85, heavy, arrives without a ring
     50  → zeta ~0.41
     100 → zeta ~0.20, lively, two visible rebounds

   Both ends shippable, which is the constraint that fixed the
   numbers rather than taste. */
private func springOf(_ tune: Double) -> (k: Double, d: Double) {
    (
        /* stiffness: how hard it is pulled toward the target */
        k: 0.08 + (tune / 100) * 0.16,
        /* decay, per frame: how much of the velocity survives */
        d: 0.62 + (tune / 100) * 0.2
    )
}

/// 會變的設定，跟著 View 傳進 model
struct RollingCounterKnobs: Equatable {
    /// how lively a digit lands, 0..100
    var bounce: Double = 45
    /// ms between one column moving and the next, 0..120
    var stagger: Double = 45
    /// 減少動態效果：直接跳到新的數字
    var still = false
}

struct RollingCounter: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// how lively a digit lands, 0..100
    var bounce: Double = 45
    /// ms between one column moving and the next, 0..120
    var stagger: Double = 45
    /// how much a spinning digit smears, 0..100
    var blur: Double = 50

    @State private var model: RollingCounterModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    /* the window a digit is seen through, and the type in it
       （跟著 Dynamic Type 放大）。The buttons are upright keys the
       full height of the inside of the box, the same height as the
       window the digits roll in, so every edge of the box is the
       same 3pt from something.
       尺寸照系統的分段控制：外框 36pt 高、內縮 3pt、字是 title3 粗細，
       放在分段控制旁邊看起來是同一家的元件 */
    @ScaledMetric(relativeTo: .body) private var cell: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var keyWidth: CGFloat = 40
    /* the slab's inset round the buttons */
    private let pad: CGFloat = 3

    /// 一個數字的寬度（等寬數字大約 0.62em）
    private var digitWidth: CGFloat { fontSize * 0.62 }
    private var separatorWidth: CGFloat { fontSize * 0.26 }

    /// range 只支援 0 以上
    init(value: Binding<Int>, in range: ClosedRange<Int>, bounce: Double = 45, stagger: Double = 45, blur: Double = 50) {
        _value = value
        self.range = range
        self.bounce = bounce
        self.stagger = stagger
        self.blur = blur
        _model = State(initialValue: RollingCounterModel(value: value.wrappedValue, range: range))
    }

    var body: some View {
        /* 3pt round each key — above, below and at the box's end —
           and the corner is the box's less that same 3, so the keys
           sit concentric in it. 這裡整個是膠囊：外框半徑 = 高度一半，
           按鍵是半徑少 3 的膠囊，跟外框同心。
           底色跟分段控制的軌道一樣、沒有框線；按鍵平常是透明的，
           按下才浮出一塊跟分段控制選中那格一樣的底 */
        HStack(spacing: 0) {
            key(-1)
            number
            key(1)
        }
        .padding(pad)
        .background(Color.er.fill, in: Capsule())
        .sensoryFeedback(.selection, trigger: model.value)
        .onChange(of: RollingCounterKnobs(bounce: bounce, stagger: stagger, still: reduceMotion), initial: true) { _, knobs in
            model.knobs = knobs
        }
        .onChange(of: model.value) { _, new in
            if value != new { value = new }
        }
        .onChange(of: value) { _, new in
            model.sync(to: new)
        }
        .onDisappear { model.finish() }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(model.value, format: .number))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.bump(1)
            case .decrement: model.bump(-1)
            @unknown default: break
            }
        }
    }

    // MARK: 按鍵

    private func key(_ dir: Int) -> some View {
        let atEnd = dir < 0 ? model.value <= range.lowerBound : model.value >= range.upperBound
        return Button {
            model.tap(dir)
        } label: {
            Image(systemName: dir < 0 ? "minus" : "plus")
                .font(.subheadline.weight(.semibold))
                .frame(width: keyWidth, height: cell)
        }
        .buttonStyle(CounterKeyStyle { pressed in model.hold(dir, pressed: pressed) })
        .disabled(atEnd)
        .accessibilityLabel(dir < 0 ? "減少" : "增加")
    }

    // MARK: 數字

    /* 原版是 the number hugs its digits：一欄出現或消失時改自己的寬度，
       膠囊跟著變寬變窄。在 iPhone 上這會讓 9 → 10、10 → 9 的時候
       兩顆按鍵被推來推去，每一格都在重新排版，看起來卡。
       所以這裡改成：寬度一開始就留好最多幾位數（0...100 就是三位），
       用不到的那幾欄只是淡掉，整排數字用位移（不重新排版）滑到正中間。
       外框從頭到尾一樣大，按鍵不會動 */
    private var number: some View {
        let shown = max(1, String(model.value).count)
        let hidden = model.places - shown
        let hiddenWidth = CGFloat(hidden) * digitWidth + (model.places > 3 && shown <= 3 ? separatorWidth : 0)
        return HStack(spacing: 0) {
            ForEach(Array((0..<model.places).reversed()), id: \.self) { p in
                column(p, on: p < shown)
                if p == 3 {
                    separator(on: shown > 3)
                }
            }
        }
        .animation(.smooth(duration: 0.25)) { content in
            content.offset(x: -hiddenWidth / 2)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(isEnabled ? Color.er.text : Color.er.textTertiary)
        // 數字永遠由左到右，阿拉伯文等 RTL 語系也一樣
        .environment(\.layoutDirection, .leftToRight)
        .padding(.horizontal, 6)
        .frame(height: cell)
        /* rolling digits fade at the window's top and bottom edge */
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: Color.er.text, location: 0.2),
                .init(color: Color.er.text, location: 0.8),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .contentShape(Rectangle())
        .highPriorityGesture(drag, including: isEnabled ? .all : .none)
    }

    private func column(_ p: Int, on: Bool) -> some View {
        let c = model.columns[p]
        let m = (c.pos.truncatingRemainder(dividingBy: 10) + 10).truncatingRemainder(dividingBy: 10)
        let smear = min(3, abs(c.vel) * 2.4) * (blur / 50)
        return VStack(spacing: 0) {
            ForEach(0..<11, id: \.self) { j in
                Text(j % 10, format: .number)
                    .frame(height: cell)
            }
        }
        .fixedSize()
        .offset(y: -m * cell)
        .blur(radius: smear > 0.15 ? smear : 0)
        .frame(width: digitWidth, height: cell, alignment: .top)
        .clipped()
        // 只有透明度跟著動畫，滾動的位置由 model 每一格自己算
        .animation(.smooth(duration: 0.2)) { content in
            content.opacity(on ? 1 : 0)
        }
    }

    private func separator(on: Bool) -> some View {
        Text(verbatim: Locale.current.groupingSeparator ?? ",")
            .fixedSize()
            .frame(width: separatorWidth)
            .animation(.smooth(duration: 0.2)) { content in
                content.opacity(on ? 1 : 0)
            }
    }

    /* ── taking the number itself ──────────────────────────── */
    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                model.dragChanged(y: g.location.y, startY: g.startLocation.y)
            }
            .onEnded { g in
                model.dragEnded(velocityY: g.velocity.height)
            }
    }
}

/// 按鍵：平常只有符號，按下浮出一塊膠囊底並縮一點。按住不放交給 model 連續加減
private struct CounterKeyStyle: ButtonStyle {
    let onPress: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.er.text : Color.er.textTertiary)
            .background {
                Capsule()
                    .fill(Color.er.surface)
                    .shadow(color: Color.er.shadow, radius: 2, y: 1)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: configuration.isPressed ? 0.11 : 0.2, bounce: 0.2), value: configuration.isPressed)
            .contentShape(Capsule())
            .onChange(of: configuration.isPressed) { _, pressed in
                onPress(pressed)
            }
    }
}

// MARK: - Model

@MainActor
@Observable
final class RollingCounterModel {
    struct Column {
        var pos: Double
        var vel: Double = 0
        var target: Double
        /// 還沒輪到的目標（Stagger）：時間到了才換上去
        var queue: [(due: CFTimeInterval, to: Double)] = []
    }

    private(set) var value: Int
    private(set) var columns: [Column]
    let places: Int
    let range: ClosedRange<Int>

    @ObservationIgnored var knobs = RollingCounterKnobs()

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var prev: CFTimeInterval = 0
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var repeated = false
    @ObservationIgnored private var lastY: CGFloat?
    @ObservationIgnored private var dragAcc: Double = 0
    @ObservationIgnored private var coast: Double = 0

    /* a step of drag, pt */
    private let px: Double = 12

    init(value: Int, range: ClosedRange<Int>) {
        let v = min(max(value, range.lowerBound), range.upperBound)
        self.value = v
        self.range = range
        places = max(1, String(range.upperBound).count)
        columns = (0..<places).map { p in
            let n = Double(v / Self.unit(p))
            return Column(pos: n, target: n)
        }
    }

    private static func unit(_ place: Int) -> Int {
        (0..<place).reduce(1) { result, _ in result * 10 }
    }

    /* ── the one way the number changes ────────────────────── */
    @discardableResult
    func bump(_ n: Int) -> Bool {
        let v = min(max(value + n, range.lowerBound), range.upperBound)
        guard v != value else { return false }
        value = v
        let now = CACurrentMediaTime()
        var cols = columns
        for p in cols.indices {
            let to = Double(v / Self.unit(p))
            if knobs.still {
                cols[p].pos = to
                cols[p].target = to
                cols[p].vel = 0
                cols[p].queue = []
            } else {
                cols[p].queue.append((due: now + Double(p) * knobs.stagger / 1000, to: to))
            }
        }
        columns = cols
        if !knobs.still { run() }
        return true
    }

    /// 外面改了綁定的值（例如另一個畫面）
    func sync(to v: Int) {
        if v != value { bump(v - value) }
    }

    /// 離開畫面：停掉迴圈，數字直接停在目標上
    func finish() {
        holdTask?.cancel()
        holdTask = nil
        coast = 0
        lastY = nil
        stop()
        columns = columns.map { c in
            let to = c.queue.last?.to ?? c.target
            return Column(pos: to, target: to)
        }
    }

    /* ── holding a button ──────────────────────────────────── */
    // 點一下在放開時加減一步（在捲動畫面裡，手指一按下就加，捲動時會誤加）；
    // 按住超過 380ms 開始連續加減，放開時就不再多加那一步
    func tap(_ dir: Int) {
        if !repeated { bump(dir) }
    }

    func hold(_ dir: Int, pressed: Bool) {
        holdTask?.cancel()
        holdTask = nil
        guard pressed else { return }
        repeated = false
        let since = CACurrentMediaTime()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            while !Task.isCancelled {
                guard let self else { return }
                let held = CACurrentMediaTime() - since
                self.repeated = true
                /* ones, then tens after a second and a half */
                self.bump(dir * (held > 1.5 ? 10 : 1))
                try? await Task.sleep(for: .milliseconds(held > 0.9 ? 55 : 90))
            }
        }
    }

    /* ── taking the number itself ──────────────────────────── */
    private func steps(_ acc: Double) -> Double {
        let n = acc > 0 ? Int((acc / px).rounded(.down)) : Int((acc / px).rounded(.up))
        // 撞到上下限就不再滑行
        if n != 0, !bump(n) { coast = 0 }
        return acc - Double(n) * px
    }

    func dragChanged(y: CGFloat, startY: CGFloat) {
        if lastY == nil {
            coast = 0
            dragAcc = 0
            lastY = startY
        }
        guard let last = lastY else { return }
        /* up is more */
        let dy = Double(last - y)
        lastY = y
        dragAcc = steps(dragAcc + dy)
    }

    func dragEnded(velocityY: CGFloat) {
        lastY = nil
        guard !knobs.still else { return }
        /* a hand that stopped before letting go threw nothing:
           DragGesture 的速度只看最後一小段，停住再放開就是 0 */
        let v = Double(-velocityY) / 60
        guard abs(v) >= 2 else { return }
        coast = v
        run()
    }

    // MARK: 迴圈

    private func run() {
        guard link == nil else { return }
        prev = 0
        let link = CADisplayLink(target: RollingCounterTicker(self), selector: #selector(RollingCounterTicker.tick(_:)))
        // ProMotion 的 iPhone 跑 120Hz（Info.plist 有 CADisableMinimumFrameDurationOnPhone），滾起來比較順
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        prev = 0
    }

    fileprivate func step(_ link: CADisplayLink) {
        let t = link.timestamp
        let dt = prev > 0 ? min(max((t - prev) * 60, 0), 2.5) : 1
        prev = t
        let (k, d) = springOf(knobs.bounce)
        var busy = false

        /* let go while it is moving and it keeps rolling and runs down */
        if abs(coast) > 0.4 {
            dragAcc = steps(dragAcc + coast * dt)
            coast *= pow(0.94, dt)
            busy = true
        } else {
            coast = 0
        }

        let now = CACurrentMediaTime()
        var cols = columns
        for i in cols.indices {
            /* targets that have waited their turn */
            while let first = cols[i].queue.first, first.due <= now {
                cols[i].queue.removeFirst()
                cols[i].target = first.to
            }
            if !cols[i].queue.isEmpty { busy = true }
            /* a column far from home jumps most of the way in whole
               turns first — it looks the same, and a flick does not
               leave the ones column spinning for a second */
            let gap = cols[i].target - cols[i].pos
            if abs(gap) > 24 {
                let sign: Double = gap > 0 ? 1 : -1
                cols[i].pos += ((gap - sign * 24) / 10).rounded() * 10
            }
            cols[i].vel += (cols[i].target - cols[i].pos) * k * dt
            cols[i].vel *= pow(d, dt)
            cols[i].pos += cols[i].vel * dt
            if abs(cols[i].target - cols[i].pos) < 0.004 && abs(cols[i].vel) < 0.004 {
                cols[i].pos = cols[i].target
                cols[i].vel = 0
            } else {
                busy = true
            }
        }
        columns = cols
        if !busy { stop() }
    }
}

/// CADisplayLink 會強引用 target，中間隔一層弱引用，model 不會被留住
@MainActor
private final class RollingCounterTicker: NSObject {
    weak var model: RollingCounterModel?

    init(_ model: RollingCounterModel) {
        self.model = model
    }

    @objc func tick(_ link: CADisplayLink) {
        if let model {
            model.step(link)
        } else {
            link.invalidate()
        }
    }
}

private struct RollingCounterPreview: View {
    @State private var value = 15

    var body: some View {
        VStack(spacing: 24) {
            RollingCounter(value: $value, in: 0...200)
            RollingCounter(value: .constant(95), in: 0...99_999)
            RollingCounter(value: .constant(20), in: 0...100)
                .disabled(true)
        }
        .padding(Theme.Spacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .erPageBackground()
    }
}

#Preview("淺色") {
    RollingCounterPreview()
}

#Preview("深色") {
    RollingCounterPreview()
        .preferredColorScheme(.dark)
}
