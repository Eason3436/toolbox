import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct RecapWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

private let recordRed = Color(red: 1.0, green: 0.27, blue: 0.23)

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activitySystemActionForegroundColor(recordRed)
                .widgetURL(RecapURL.open)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        StatusBadge(state: context.state, isLecture: context.attributes.isLecture, size: 36)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(modeTitle(context))
                                .font(.subheadline.weight(.semibold))
                            Text(statusText(context))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: context.state)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.state.isPaused ? .orange : recordRed)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        if context.attributes.isLecture, let line = context.state.line, !line.isEmpty {
                            Text(line)
                                .font(.callout)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentTransition(.opacity)
                        }
                        ActionRow()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : symbol(context))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(context.state.isPaused ? .orange : recordRed)
                    .symbolEffect(.variableColor.iterative, isActive: !context.state.isPaused)
                    .padding(.leading, 2)
            } compactTrailing: {
                ElapsedText(state: context.state)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(context.state.isPaused ? .orange : recordRed)
                    .frame(width: 50, alignment: .trailing)
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : symbol(context))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(context.state.isPaused ? .orange : recordRed)
            }
            .keylineTint(recordRed)
            .widgetURL(RecapURL.open)
        }
    }
}

private func symbol(_ context: ActivityViewContext<RecordingActivityAttributes>) -> String {
    context.attributes.isLecture ? "captions.bubble.fill" : "waveform"
}

private func modeTitle(_ context: ActivityViewContext<RecordingActivityAttributes>) -> String {
    context.attributes.isLecture ? "課堂模式" : "全天錄音"
}

private func statusText(_ context: ActivityViewContext<RecordingActivityAttributes>) -> String {
    let s = context.state
    if s.isPaused { return "已暫停・點一下繼續" }
    if let stopAt = s.stopAt { return "錄到 \(stopAt.formatted(date: .omitted, time: .shortened))" }
    if context.attributes.isLecture { return s.segmentCount > 0 ? "\(s.segmentCount) 句・即時翻譯中" : "正在聽…" }
    return s.segmentCount > 0 ? "已存 \(s.segmentCount) 段" : "收音中"
}

/// 計時（從開始錄音算起）；暫停時顯示「暫停」。
private struct ElapsedText: View {
    let state: RecordingActivityAttributes.ContentState
    var body: some View {
        if state.isPaused {
            Text("暫停")
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false, showsHours: true)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 圓形狀態圖示。
private struct StatusBadge: View {
    let state: RecordingActivityAttributes.ContentState
    let isLecture: Bool
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill((state.isPaused ? Color.orange : recordRed).gradient)
            Image(systemName: state.isPaused ? "pause.fill" : (isLecture ? "captions.bubble.fill" : "waveform"))
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// 「最近 15 分鐘重點」＋「停止」。
private struct ActionRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Link(destination: RecapURL.quick(minutes: 15)) {
                Label("最近 15 分鐘重點", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(.white.opacity(0.15), in: .capsule)
            }
            Button(intent: StopFromActivityIntent()) {
                Label("停止", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 84, minHeight: 40)
                    .background(recordRed.opacity(0.9), in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StatusBadge(state: context.state, isLecture: context.attributes.isLecture, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recap・\(modeTitle(context))")
                        .font(.headline)
                    Text(statusText(context))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                ElapsedText(state: context.state)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(context.state.isPaused ? .orange : recordRed)
                    .frame(maxWidth: 130, alignment: .trailing)
            }
            if context.attributes.isLecture, let line = context.state.line, !line.isEmpty {
                Text(line)
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LockActionRow()
        }
        .padding(16)
    }
}

/// 鎖定畫面用的按鈕（跟著系統深淺色）。
private struct LockActionRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Link(destination: RecapURL.quick(minutes: 15)) {
                Label("最近 15 分鐘重點", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(.fill.tertiary, in: .capsule)
            }
            .foregroundStyle(.primary)
            Button(intent: StopFromActivityIntent()) {
                Label("停止", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 84, minHeight: 38)
                    .background(recordRed, in: .capsule)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}
