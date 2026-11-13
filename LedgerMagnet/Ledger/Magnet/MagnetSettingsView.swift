import SwiftUI

// MARK: - 設定 → 磁力

struct MagnetSettingsView: View {
    @State private var calibrating = false

    var body: some View {
        @Bindable var field = MagnetField.shared
        Form {
            Section {
                MagnetLiveView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .settingsRow()

            Section {
                Toggle(isOn: $field.enabled) { SettingsRowLabel("磁力效果", "sensor") }
                LabeledContent {
                    Slider(value: $field.force, in: 0.4...2)
                        .frame(maxWidth: 170)
                } label: {
                    SettingsRowLabel("吸力", "arrow.down.right.and.arrow.up.left")
                }
            } footer: {
                if !field.available {
                    Text("這支手機沒有磁力計。")
                }
            }
            .settingsRow()

            Section {
                Button { calibrating = true } label: {
                    LabeledContent {
                        Text(field.calibrated ? "已校正" : "未校正")
                    } label: {
                        SettingsRowLabel("校正磁鐵", "scope")
                    }
                }
                if field.calibrated {
                    Button(role: .destructive) { field.saveCalibration(nil) } label: {
                        SettingsRowLabel("清除校正", "arrow.counterclockwise")
                    }
                }
            } header: {
                SettingsHeader("校正")
            } footer: {
                Text("換手機或換磁鐵時重新校正一次。磁鐵不要貼著相機鏡頭。開啟「減少動態效果」時元素不會移動。")
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("磁力")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $calibrating) {
            MagnetCalibrationView()
                .presentationBackground(Palette.background)
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - 即時讀數：手機外框＋磁鐵位置＋吸力

struct MagnetLiveView: View {
    var highlight: MagnetSide? = nil

    var body: some View {
        let field = MagnetField.shared
        VStack(spacing: 14) {
            PhoneDiagram(highlight: highlight, dot: dotPosition(field), dotStrength: field.pull)
                .frame(width: 120, height: 220)
            Gauge(value: field.pull) {
                EmptyView()
            } currentValueLabel: {
                Text("\(field.strength, format: .number.precision(.fractionLength(0))) µT")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .frame(maxWidth: 220)
            if field.needsCompassCalibration {
                Label("拿起手機在空中畫幾次 8 字", systemImage: "gyroscope")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            } else if field.tooClose {
                Label("太近了", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func dotPosition(_ field: MagnetField) -> CGPoint? {
        guard let p = field.point, field.screenSize.width > 0 else { return nil }
        return CGPoint(x: p.x / field.screenSize.width, y: p.y / field.screenSize.height)
    }
}

/// 手機外框；dot 是 0…1 的位置
struct PhoneDiagram: View {
    var highlight: MagnetSide?
    var dot: CGPoint?
    var dotStrength: Double

    var body: some View {
        GeometryReader { proxy in
            let w: CGFloat = proxy.size.width
            let h: CGFloat = proxy.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 3)
                Capsule()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 34, height: 10)
                    .position(x: w / 2, y: 16)
                if let highlight {
                    sideMarker(highlight, w: w, h: h)
                }
                if let dot {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 14 + 14 * dotStrength, height: 14 + 14 * dotStrength)
                        .shadow(color: Color.accentColor.opacity(0.6), radius: 8)
                        .position(x: dot.x * w, y: dot.y * h)
                        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.75), value: dot)
                }
            }
        }
    }

    @ViewBuilder
    private func sideMarker(_ side: MagnetSide, w: CGFloat, h: CGFloat) -> some View {
        let horizontal: Bool = side == .top || side == .bottom
        let length: CGFloat = horizontal ? w * 0.6 : h * 0.4
        Capsule()
            .fill(Color.accentColor)
            .frame(width: horizontal ? length : 6, height: horizontal ? 6 : length)
            .position(x: side.anchor.x * w, y: side.anchor.y * h)
            .phaseAnimator([0.35, 1.0]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.7) }
    }
}

// MARK: - 校正流程

@MainActor
@Observable
final class MagnetCalibrator {
    enum Step: Equatable {
        case quiet
        case place(MagnetSide)
        case remove(MagnetSide)
        case done
    }

    private(set) var step: Step = .quiet
    /// 目前這一步的進度 0…1
    private(set) var progress: Double = 0

    @ObservationIgnored private var samples: [Vec3] = []
    @ObservationIgnored private var noise: Double = 6
    @ObservationIgnored private var sides: [MagnetSide: Vec3] = [:]
    @ObservationIgnored private let order: [MagnetSide] = [.top, .right, .bottom, .left]

    func begin() {
        step = .quiet
        progress = 0
        samples = []
        sides = [:]
        MagnetField.shared.resetBaseline()
        MagnetField.shared.sampleSink = { [weak self] d in self?.feed(d) }
    }

    func cancel() {
        MagnetField.shared.sampleSink = nil
    }

    private func feed(_ d: Vec3) {
        switch step {
        case .quiet:
            // 2 秒（100 筆）沒有磁鐵，量雜訊
            samples.append(d)
            progress = min(Double(samples.count) / 100, 1)
            if samples.count >= 100 {
                let mean: Double = samples.map(\.length).reduce(0, +) / Double(samples.count)
                noise = max(3, mean * 1.5)
                samples = []
                next(after: nil)
            }
        case .place(let side):
            // 變化夠大而且穩定 0.8 秒（40 筆）才記下
            let lo: Double = MagnetMath.threshold(noise: noise) * 2.5
            guard d.length > lo else {
                samples = []
                progress = 0
                return
            }
            if let first = samples.first, d.normalized.dot(first.normalized) < 0.9 {
                samples = []
            }
            samples.append(d)
            progress = min(Double(samples.count) / 40, 1)
            if samples.count >= 40 {
                let sum: Vec3 = samples.reduce(Vec3.zero) { $0 + $1 }
                sides[side] = sum * (1 / Double(samples.count))
                samples = []
                progress = 0
                step = .remove(side)
            }
        case .remove(let side):
            if d.length < MagnetMath.threshold(noise: noise) * 1.5 {
                samples.append(d)
                if samples.count >= 15 {
                    samples = []
                    next(after: side)
                }
            } else {
                samples = []
            }
        case .done:
            break
        }
    }

    private func next(after side: MagnetSide?) {
        var idx: Int = 0
        if let side, let i = order.firstIndex(of: side) { idx = i + 1 }
        if idx < order.count {
            step = .place(order[idx])
        } else {
            step = .done
            MagnetField.shared.sampleSink = nil
            MagnetField.shared.saveCalibration(MagnetCalibrationData(noise: noise, sides: sides))
        }
    }
}

struct MagnetCalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var calibrator = MagnetCalibrator()

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 0)
                MagnetLiveView(highlight: highlight)
                Text(instruction)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 24)
                if calibrator.step != .done {
                    ProgressView(value: calibrator.progress)
                        .frame(maxWidth: 200)
                }
                Spacer(minLength: 0)
            }
            .animation(.snappy, value: calibrator.step)
            .frame(maxWidth: .infinity)
            .background(Palette.background)
            .navigationTitle("校正磁鐵")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                }
                if calibrator.step == .done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成", systemImage: "checkmark") { dismiss() }
                    }
                }
            }
        }
        .onAppear { calibrator.begin() }
        .onDisappear { calibrator.cancel() }
        .sensoryFeedback(trigger: calibrator.step) { _, s in
            switch s {
            case .done: .success
            case .remove: .impact(weight: .medium)
            default: .selection
            }
        }
    }

    private var highlight: MagnetSide? {
        switch calibrator.step {
        case .place(let s): s
        default: nil
        }
    }

    private var instruction: String {
        switch calibrator.step {
        case .quiet: "把磁鐵拿遠，手機平放不要動"
        case .place(let s): "把磁鐵貼在\(s.title)\n同一面朝著手機"
        case .remove: "拿開磁鐵"
        case .done: "校正完成"
        }
    }
}
