import AppIntents
import SwiftUI

private let snippetRed = Color(red: 1.0, green: 0.27, blue: 0.23)

/// Siri／捷徑裡的互動錄音卡：顯示計時，可以直接暫停、繼續、停止，不用打開 App。
/// 按下按鈕後系統會重新執行這個 SnippetIntent，卡片就換成最新狀態。
struct RecordingSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "錄音狀態"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let recorder = AppModel.shared.recorder
        let status = RecordingSnippetView.Status(
            active: recorder.isActive,
            paused: recorder.state == .paused || recorder.state == .interrupted,
            lecture: recorder.mode == .lecture,
            subject: recorder.lecture?.lecture.subject,
            startedAt: recorder.startedAt,
            stopAt: recorder.stopAt,
            segments: recorder.segmentsThisSession
        )
        return .result(view: RecordingSnippetView(status: status))
    }
}

struct RecordingSnippetView: View {
    struct Status {
        var active: Bool
        var paused: Bool
        var lecture: Bool
        var subject: SchoolSubject?
        var startedAt: Date?
        var stopAt: Date?
        var segments: Int
    }

    let status: Status

    private var tint: Color { !status.active ? .secondary : (status.paused ? .orange : snippetRed) }

    private var title: String {
        if status.lecture {
            if let subject = status.subject, subject != .general { return subject.isSeminar ? "講座" : "\(subject.title)課" }
            return "課堂"
        }
        return "全天錄音"
    }

    private var detail: String {
        if !status.active { return "錄音已儲存" }
        if status.paused { return "已暫停" }
        if let stopAt = status.stopAt { return "錄到 \(stopAt.formatted(date: .omitted, time: .shortened))" }
        return status.lecture ? "下課後整理重點" : (status.segments > 0 ? "已存 \(status.segments) 段" : "收音中")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: !status.active ? "checkmark.circle.fill" : (status.paused ? "pause.circle.fill" : "record.circle"))
                        .contentTransition(.symbolEffect(.replace))
                    Text(title)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                if status.active, !status.paused, let startedAt = status.startedAt {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false, showsHours: true)
                        .font(.system(size: 36, weight: .medium).monospacedDigit())
                        .contentTransition(.numericText())
                } else {
                    Text(status.active ? "暫停" : "已停止")
                        .font(.system(size: 36, weight: .medium))
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if status.active {
                HStack(spacing: 10) {
                    if status.paused {
                        Button(intent: ResumeFromActivityIntent()) {
                            circle("play.fill", fill: snippetRed.opacity(0.2), fg: snippetRed)
                        }
                        .accessibilityLabel("繼續錄音")
                    } else {
                        Button(intent: PauseFromActivityIntent()) {
                            circle("pause.fill", fill: Color.orange.opacity(0.2), fg: .orange)
                        }
                        .accessibilityLabel("暫停")
                    }
                    Button(intent: StopFromActivityIntent()) {
                        circle("stop.fill", fill: Color.secondary.opacity(0.18), fg: .primary)
                    }
                    .accessibilityLabel("停止")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    private func circle(_ name: String, fill: Color, fg: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(fg)
            .frame(width: 48, height: 48)
            .background(fill, in: .circle)
    }
}

/// 今日 Recap、最近幾分鐘重點的靜態卡：標題、一句話、三個重點、待辦。
struct RecapSnippetView: View {
    let caption: String
    let title: String
    var overview: String?
    let points: [String]
    var todos: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(points.prefix(3).enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(.tint).frame(width: 5, height: 5)
                            Text(point).font(.subheadline).lineLimit(2)
                        }
                    }
                }
            }
            if !todos.isEmpty {
                Divider()
                ForEach(Array(todos.prefix(3).enumerated()), id: \.offset) { _, todo in
                    Label(todo, systemImage: "circle")
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
