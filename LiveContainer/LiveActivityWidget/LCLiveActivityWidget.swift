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
                .activitySystemActionForegroundColor(accent(context))
                .widgetURL(context.attributes.launchURL)
        } dynamicIsland: { context in
            DynamicIsland {
                // Leading / trailing sit beside the camera; center and bottom go below it.
                DynamicIslandExpandedRegion(.leading) {
                    IconBadge(name: iconName(context), tint: accent(context), size: 44)
                        .padding(.leading, 6)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingValue(state: context.state, tint: accent(context))
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .padding(.trailing, 8)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(secondaryLine(context))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let progress = clampedProgress(context.state) {
                        ProgressView(value: progress)
                            .tint(accent(context))
                            .padding(.horizontal, 8)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: iconName(context))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(accent(context))
                    .padding(.leading, 2)
            } compactTrailing: {
                CompactTrailing(state: context.state, tint: accent(context))
            } minimal: {
                if let progress = clampedProgress(context.state) {
                    ProgressRing(progress: progress, tint: accent(context))
                } else {
                    Image(systemName: iconName(context))
                        .foregroundStyle(accent(context))
                }
            }
            .keylineTint(accent(context))
            .widgetURL(context.attributes.launchURL)
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let context: ActivityViewContext<LCLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(name: iconName(context), tint: accent(context), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(secondaryLine(context))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                TrailingValue(state: context.state, tint: accent(context))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            if let progress = clampedProgress(context.state) {
                ProgressView(value: progress)
                    .tint(accent(context))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
            // Text reads better than a tiny ring next to the camera; the ring stays for `minimal`.
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .font(.body.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .foregroundStyle(tint)
                .padding(.trailing, 2)
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
            Circle().stroke(tint.opacity(0.35), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }
}

/// SF Symbol in a soft tinted circle.
private struct IconBadge: View {
    let name: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.2), in: Circle())
    }
}

// MARK: - Helpers

/// Subtitle, or the app name when there is none, so the layout keeps two lines.
private func secondaryLine(_ context: ActivityViewContext<LCLiveActivityAttributes>) -> String {
    if let subtitle = context.state.subtitle, !subtitle.isEmpty {
        return "\(context.attributes.appName) · \(subtitle)"
    }
    return context.attributes.appName
}


private func clampedProgress(_ state: LCLiveActivityAttributes.ContentState) -> Double? {
    guard let progress = state.progress, progress.isFinite else { return nil }
    return min(max(progress, 0), 1)
}

private func iconName(_ context: ActivityViewContext<LCLiveActivityAttributes>) -> String {
    context.state.systemImage ?? context.attributes.systemImage ?? "app.badge"
}

private func accent(_ context: ActivityViewContext<LCLiveActivityAttributes>) -> Color {
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
