//
//  LCLiveActivityWidget.swift
//  LCLiveActivityWidget
//
//  Added by Eason3436/toolbox: draws LCLiveActivityAttributes activities
//  (lock screen + Dynamic Island) for apps running inside LiveContainer.
//  Built by .github/workflows/livecontainer.yml and copied into
//  LiveContainer.app/PlugIns.
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
            LockScreenView(context: context)
                .activitySystemActionForegroundColor(tint(context))
                .widgetURL(context.attributes.launchURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.appName)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: symbol(context))
                            .foregroundStyle(tint(context))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingValue(state: context.state, tint: tint(context))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let subtitle = context.state.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let progress = clampedProgress(context.state) {
                            ProgressView(value: progress)
                                .tint(tint(context))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: symbol(context))
                    .foregroundStyle(tint(context))
            } compactTrailing: {
                CompactTrailing(state: context.state, tint: tint(context))
            } minimal: {
                if let progress = clampedProgress(context.state) {
                    ProgressRing(progress: progress, tint: tint(context))
                } else {
                    Image(systemName: symbol(context))
                        .foregroundStyle(tint(context))
                }
            }
            .keylineTint(tint(context))
            .widgetURL(context.attributes.launchURL)
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let context: ActivityViewContext<LCLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: symbol(context))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint(context))
                    .frame(width: 40, height: 40)
                    .background(tint(context).opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.appName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = context.state.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                TrailingValue(state: context.state, tint: tint(context))
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
            if let progress = clampedProgress(context.state) {
                ProgressView(value: progress)
                    .tint(tint(context))
            }
        }
        .padding(16)
    }
}

// MARK: - Pieces

/// Timer, percentage or short text, whichever the app gave.
private struct TrailingValue: View {
    let state: LCLiveActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        if let start = state.timerStart {
            Text(start, style: .timer)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110, alignment: .trailing)
                .foregroundStyle(tint)
        } else if let end = state.timerEnd {
            Text(end, style: .timer)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110, alignment: .trailing)
                .foregroundStyle(tint)
        } else if let progress = clampedProgress(state) {
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .foregroundStyle(tint)
        } else if let text = state.compactText, !text.isEmpty {
            Text(text)
                .lineLimit(1)
                .foregroundStyle(tint)
        }
    }
}

private struct CompactTrailing: View {
    let state: LCLiveActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        if let start = state.timerStart {
            Text(start, style: .timer)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 50, alignment: .trailing)
                .foregroundStyle(tint)
        } else if let end = state.timerEnd {
            Text(end, style: .timer)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 50, alignment: .trailing)
                .foregroundStyle(tint)
        } else if let progress = clampedProgress(state) {
            ProgressRing(progress: progress, tint: tint)
        } else if let text = state.compactText, !text.isEmpty {
            Text(text)
                .lineLimit(1)
                .frame(maxWidth: 64, alignment: .trailing)
                .foregroundStyle(tint)
        } else {
            Text(state.title)
                .lineLimit(1)
                .frame(maxWidth: 64, alignment: .trailing)
        }
    }
}

private struct ProgressRing: View {
    let progress: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Helpers

private func clampedProgress(_ state: LCLiveActivityAttributes.ContentState) -> Double? {
    guard let progress = state.progress, progress.isFinite else { return nil }
    return min(max(progress, 0), 1)
}

private func symbol(_ context: ActivityViewContext<LCLiveActivityAttributes>) -> String {
    context.state.systemImage ?? context.attributes.systemImage ?? "app.badge"
}

private func tint(_ context: ActivityViewContext<LCLiveActivityAttributes>) -> Color {
    color(hex: context.state.tintHex) ?? color(hex: context.attributes.tintHex) ?? .accentColor
}

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
