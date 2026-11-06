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

/// 版面參考系統「語音備忘錄」與「計時器」的即時動態：
/// 左邊狀態＋大計時，右邊圓形按鈕；動態島精簡模式只放圖示與時間。
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(recordRed)
                .widgetURL(RecapURL.open)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActionButtons(state: context.state, dark: true, size: 50)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(context.state.isPaused ? "已暫停" : modeTitle(context))
                            .font(.subheadline.weight(.semibold))
                        ElapsedText(state: context.state)
                            .font(.system(size: 40, weight: .regular).monospacedDigit())
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(stateTint(context.state))
                    .frame(maxHeight: .infinity, alignment: .center)
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.attributes.isLecture, let line = context.state.line, !line.isEmpty {
                        CaptionLine(context: context, dark: true)
                            .padding(.horizontal, 8)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(stateTint(context.state))
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: !context.state.isPaused)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.leading, 4)
            } compactTrailing: {
                ElapsedText(state: context.state)
                    .font(.body.weight(.medium).monospacedDigit())
                    .foregroundStyle(stateTint(context.state))
                    .contentTransition(.numericText())
                    .frame(width: 52, alignment: .trailing)
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(stateTint(context.state))
                    .contentTransition(.symbolEffect(.replace))
            }
            .keylineTint(recordRed)
            .widgetURL(RecapURL.open)
        }
    }
}

private func stateTint(_ state: RecordingActivityAttributes.ContentState) -> Color {
    state.isPaused ? .orange : recordRed
}

private func symbol(_ context: ActivityViewContext<RecordingActivityAttributes>) -> String {
    context.attributes.isLecture ? "captions.bubble.fill" : "waveform"
}

private func modeTitle(_ context: ActivityViewContext<RecordingActivityAttributes>) -> String {
    context.attributes.isLecture ? "課堂" : "全天錄音"
}

private func statusText(_ context: ActivityViewContext<RecordingActivityAttributes>) -> String {
    let s = context.state
    if s.manualPause { return "已暫停" }
    if s.isPaused { return "被打斷" }
    if let stopAt = s.stopAt { return "錄到 \(stopAt.formatted(date: .omitted, time: .shortened))" }
    if context.attributes.isLecture { return s.segmentCount > 0 ? "\(s.segmentCount) 句" : "正在聽" }
    return s.segmentCount > 0 ? "已存 \(s.segmentCount) 段" : "收音中"
}

/// 小標：彩色圖示＋模式＋狀態，像系統即時動態的標題列。
private struct StatusLabel: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: context.state.isPaused ? "pause.circle.fill" : "record.circle")
                .foregroundStyle(stateTint(context.state))
                .contentTransition(.symbolEffect(.replace))
            Text(modeTitle(context))
                .foregroundStyle(stateTint(context.state))
            Text(statusText(context))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
    }
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

/// 課堂模式最新一句翻譯，換句時由下往上推入。
private struct CaptionLine: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    var dark = false
    var body: some View {
        if context.attributes.isLecture, let line = context.state.line, !line.isEmpty {
            Text(line)
                .font(.callout)
                .foregroundStyle(dark ? Color.white : Color.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(line)
                .transition(.push(from: .bottom))
        } else {
            Link(destination: RecapURL.quick(minutes: 15)) {
                Label("最近 15 分鐘重點", systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
    }
}

/// 圓形按鈕：暫停／繼續、停止。
private struct ActionButtons: View {
    let state: RecordingActivityAttributes.ContentState
    var dark = false
    var size: CGFloat = 48

    private var neutralFill: AnyShapeStyle {
        dark ? AnyShapeStyle(Color.white.opacity(0.18)) : AnyShapeStyle(.fill.secondary)
    }

    var body: some View {
        HStack(spacing: 10) {
            if state.isPaused {
                Button(intent: ResumeFromActivityIntent()) {
                    circle("play.fill", fill: AnyShapeStyle(recordRed.opacity(0.3)), fg: recordRed)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("繼續錄音")
            } else {
                Button(intent: PauseFromActivityIntent()) {
                    circle("pause.fill", fill: AnyShapeStyle(Color.orange.opacity(0.3)), fg: .orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("暫停")
            }
            Button(intent: StopFromActivityIntent()) {
                circle("stop.fill", fill: neutralFill, fg: dark ? .white : .primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止")
        }
    }

    private func circle(_ name: String, fill: AnyShapeStyle, fg: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(fg)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .background(fill, in: .circle)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ActionButtons(state: context.state, size: 50)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    StatusLabel(context: context)
                    ElapsedText(state: context.state)
                        .font(.system(size: 44, weight: .regular).monospacedDigit())
                        .foregroundStyle(stateTint(context.state))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            CaptionLine(context: context)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
