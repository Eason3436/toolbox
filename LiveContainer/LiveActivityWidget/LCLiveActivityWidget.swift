//
//  LCLiveActivityWidget.swift
//  LCLiveActivityWidget
//
//  Added by Eason3436/toolbox: draws LCLiveActivityAttributes activities
//  (lock screen + Dynamic Island) for apps running inside LiveContainer.
//  Built by .github/workflows/livecontainer.yml and copied into
//  LiveContainer.app/PlugIns.
//
//  Layout follows Apple's Human Interface Guidelines for Live Activities:
//  - compact leading identifies the activity (glyph or waveform), compact
//    trailing shows the one key value, and the two read as one unit
//  - minimal shows a single glyph or a progress ring
//  - expanded keeps the same glyph and value at the leading/trailing edges,
//    and puts the title and supporting details below
//  - the lock screen uses 14 pt margins and the same hierarchy, stays short,
//    and shows a clear finished state and an out-of-date hint
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LCLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        LCLiveActivityWidget()
    }
}

struct LCLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LCLiveActivityAttributes.self) { context in
            LockScreenView(model: Model(context))
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(Model(context).accent)
                .widgetURL(context.attributes.launchURL)
        } dynamicIsland: { context in
            let model = Model(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    GlyphBadge(model: model, size: 44)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ValueText(model: model, compact: false)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedDetails(model: model)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
            } compactLeading: {
                CompactGlyph(model: model)
                    .padding(.leading, 2)
            } compactTrailing: {
                CompactValue(model: model)
                    .padding(.trailing, 2)
            } minimal: {
                MinimalView(model: model)
            }
            .keylineTint(model.accent)
            .widgetURL(context.attributes.launchURL)
        }
    }
}

// MARK: - Model

/// Everything the views need, worked out once from the activity.
private struct Model {
    let appName: String
    let title: String
    let subtitle: String?
    let detail: String?
    let glyph: String
    let accent: Color
    let progress: Double?
    let levels: [Double]
    let isFinished: Bool
    let isStale: Bool
    let value: Value

    enum Value {
        case countUp(Date)
        case countDown(Date)
        case fixed(TimeInterval)
        case percent(Double)
        case text(String)
        case none
    }

    init(_ context: ActivityViewContext<LCLiveActivityAttributes>) {
        let state = context.state
        let attributes = context.attributes
        appName = attributes.appName
        title = state.title
        subtitle = state.subtitle.flatMap { $0.isEmpty ? nil : $0 }
        detail = state.detail.flatMap { $0.isEmpty ? nil : $0 }
        isFinished = state.isFinished ?? false
        isStale = context.isStale
        accent = color(hex: state.tintHex) ?? color(hex: attributes.tintHex) ?? .accentColor
        if let raw = state.progress, raw.isFinite {
            progress = min(max(raw, 0), 1)
        } else {
            progress = nil
        }
        levels = (state.levels ?? []).map { min(max($0, 0), 1) }

        let baseGlyph = state.systemImage ?? attributes.systemImage ?? "app.fill"
        glyph = isFinished ? "checkmark" : (state.pausedElapsed != nil ? "pause.fill" : baseGlyph)

        if let paused = state.pausedElapsed {
            value = .fixed(paused)
        } else if isFinished, let start = state.timerStart {
            value = .fixed(max(0, Date().timeIntervalSince(start)))
        } else if let start = state.timerStart {
            value = .countUp(start)
        } else if let end = state.timerEnd, !isFinished {
            value = .countDown(end)
        } else if let progress {
            value = .percent(progress)
        } else if let text = state.compactText, !text.isEmpty {
            value = .text(text)
        } else {
            value = .none
        }
    }

    /// Timers longer than an hour need room for h:mm:ss.
    var needsHours: Bool {
        switch value {
        case .countUp(let start): return Date().timeIntervalSince(start) >= 3300
        case .countDown(let end): return end.timeIntervalSinceNow >= 3600
        case .fixed(let seconds): return seconds >= 3600
        default: return false
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                GlyphBadge(model: model, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = model.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .id(subtitle)
                            .transition(.push(from: .bottom))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ValueText(model: model, compact: false)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
            }
            if let progress = model.progress, !model.isFinished {
                ProgressView(value: progress)
                    .tint(model.accent)
            }
            FooterLine(model: model)
        }
        .padding(14)
    }
}

/// App name on the left; detail or an out-of-date hint on the right.
private struct FooterLine: View {
    let model: Model

    var body: some View {
        HStack(spacing: 6) {
            Text(model.appName)
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.isStale && !model.isFinished {
                Label("可能不是最新狀態", systemImage: "exclamationmark.arrow.circlepath")
                    .lineLimit(1)
            } else if let detail = model.detail {
                Text(detail)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Dynamic Island

private struct ExpandedDetails: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(.headline)
                .lineLimit(1)
            if let subtitle = model.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .id(subtitle)
                    .transition(.push(from: .bottom))
            }
            if let progress = model.progress, !model.isFinished {
                ProgressView(value: progress)
                    .tint(model.accent)
            }
            FooterLine(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactGlyph: View {
    let model: Model

    var body: some View {
        if model.levels.count >= 3 && !model.isFinished {
            Waveform(levels: model.levels, accent: model.accent)
        } else {
            Image(systemName: model.glyph)
                .font(.body.weight(.semibold))
                .foregroundStyle(model.accent)
        }
    }
}

private struct CompactValue: View {
    let model: Model

    var body: some View {
        switch model.value {
        case .percent(let progress):
            ProgressRing(progress: progress, accent: model.accent, glyph: nil)
        case .none:
            if let progress = model.progress {
                ProgressRing(progress: progress, accent: model.accent, glyph: nil)
            } else {
                Image(systemName: model.isFinished ? "checkmark" : "ellipsis")
                    .foregroundStyle(model.accent)
            }
        default:
            ValueText(model: model, compact: true)
                .font(.body.weight(.semibold))
                .frame(width: model.needsHours ? 64 : 44, alignment: .trailing)
        }
    }
}

private struct MinimalView: View {
    let model: Model

    var body: some View {
        if let progress = model.progress, !model.isFinished {
            ProgressRing(progress: progress, accent: model.accent, glyph: model.glyph)
        } else {
            Image(systemName: model.glyph)
                .font(.body.weight(.semibold))
                .foregroundStyle(model.accent)
        }
    }
}

// MARK: - Pieces

/// The activity's glyph in a tinted circle.
private struct GlyphBadge: View {
    let model: Model
    let size: CGFloat

    var body: some View {
        Image(systemName: model.glyph)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(model.accent)
            .frame(width: size, height: size)
            .background(model.accent.opacity(0.2), in: Circle())
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

/// The key value: timer, paused time, percentage or short text.
private struct ValueText: View {
    let model: Model
    let compact: Bool

    var body: some View {
        Group {
            switch model.value {
            case .countUp(let start):
                Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: true)
                    .multilineTextAlignment(.trailing)
            case .countDown(let end):
                Text(timerInterval: Date()...max(end, Date()), countsDown: true, showsHours: true)
                    .multilineTextAlignment(.trailing)
            case .fixed(let seconds):
                Text(Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
            case .percent(let progress):
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .contentTransition(.numericText(value: progress))
            case .text(let text):
                Text(text)
                    .frame(maxWidth: compact ? 64 : 120, alignment: .trailing)
            case .none:
                EmptyView()
            }
        }
        .monospacedDigit()
        .foregroundStyle(model.isFinished ? Color.secondary : model.accent)
    }
}

private struct ProgressRing: View {
    let progress: Double
    let accent: Color
    let glyph: String?

    var body: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}

/// A few bars that follow recent audio levels.
private struct Waveform: View {
    let levels: [Double]
    let accent: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.suffix(6).enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(accent)
                    .frame(width: 3, height: 4 + 14 * level)
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}

// MARK: - Color

private func color(hex: String?) -> Color? {
    guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
    let hasAlpha = text.count == 8
    let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
    return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
}
