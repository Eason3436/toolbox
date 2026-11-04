import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RecapWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.35))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.isLecture ? "課堂" : "錄音中", systemImage: icon(context))
                        .font(.headline)
                        .foregroundStyle(context.state.isPaused ? .orange : .red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerText(state: context.state)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let line = context.state.line, !line.isEmpty {
                            Text(line)
                                .font(.body)
                                .lineLimit(3)
                        }
                        HStack {
                            Text(context.state.isPaused ? "已暫停" : "已存 \(context.state.segmentCount) 段")
                            if let stopAt = context.state.stopAt {
                                Spacer()
                                Text("錄到 \(stopAt, style: .time)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: icon(context))
                    .foregroundStyle(context.state.isPaused ? .orange : .red)
            } compactTrailing: {
                TimerText(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: icon(context))
                    .foregroundStyle(context.state.isPaused ? .orange : .red)
            }
        }
    }

    private func icon(_ context: ActivityViewContext<RecordingActivityAttributes>) -> String {
        if context.state.isPaused { return "pause.circle.fill" }
        return context.attributes.isLecture ? "captions.bubble.fill" : "waveform"
    }
}

private struct TimerText: View {
    let state: RecordingActivityAttributes.ContentState
    var body: some View {
        if state.isPaused {
            Text("暫停")
        } else {
            Text(state.startedAt, style: .timer)
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.isLecture ? "Recap 課堂模式" : "Recap 錄音中",
                      systemImage: context.state.isPaused ? "pause.circle.fill" : "record.circle")
                    .font(.headline)
                    .foregroundStyle(context.state.isPaused ? .orange : .red)
                Spacer()
                TimerText(state: context.state)
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            if let line = context.state.line, !line.isEmpty {
                Text(line)
                    .font(.body)
                    .lineLimit(3)
            }
            HStack {
                Text(context.state.isPaused ? "錄音被中斷，打開 App 繼續" : "已存 \(context.state.segmentCount) 段")
                Spacer()
                if let stopAt = context.state.stopAt {
                    Text("錄到 \(stopAt, style: .time)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
