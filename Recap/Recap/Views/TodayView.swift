import AppIntents
import SwiftUI

struct TodayView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    RecorderCard()
                    DayContentView(dayKey: DayKey.today, isToday: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationTitle("今日 Recap")
            .navigationDestinations()
        }
    }
}

/// 錄音控制卡片。
struct RecorderCard: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router
    @State private var error: String?

    var body: some View {
        Card {
            if recorder.isActive {
                activeContent
            } else {
                idleContent
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: recorder.isActive)
        .animation(.smooth, value: recorder.isPowerSaving)
        .animation(.smooth, value: error)
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("沒有在錄音").font(.headline)
                    if let next = nextScheduleText {
                        Text(next).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("按下開始，App 退到背景也會繼續收音").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button {
                    start(nil)
                } label: {
                    Label("開始錄音", systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)

                Menu {
                    Button("錄 30 分鐘") { start(30 * 60) }
                    Button("錄 1 小時") { start(3600) }
                    Button("錄 2 小時") { start(7200) }
                    Button("錄 4 小時") { start(4 * 3600) }
                    Button("錄 8 小時") { start(8 * 3600) }
                } label: {
                    Image(systemName: "timer")
                        .font(.headline)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("錄一段時間")
            }
        }
    }

    private var activeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: recorder.state == .interrupted || recorder.state == .paused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(recorder.state == .interrupted || recorder.state == .paused ? .orange : .red)
                    .symbolEffect(.pulse, isActive: recorder.state == .recording)
                Text(statusTitle).font(.headline)
                Spacer()
                if let started = recorder.startedAt {
                    Text(started, style: .timer).font(.title3.monospacedDigit().weight(.semibold))
                }
            }
            LevelMeter(level: recorder.level)
            if recorder.isPowerSaving {
                Label("省電中：附近沒人在說話，有人靠近說話會自動恢復", systemImage: "leaf.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            HStack {
                if let stopAt = recorder.stopAt {
                    Label("錄到 \(stopAt.hm)", systemImage: "clock")
                } else {
                    Label("一直錄到你按停止", systemImage: "infinity")
                }
                Spacer()
                if recorder.mode == .allDay {
                    Text("本次已存 \(recorder.segmentsThisSession) 段")
                        .contentTransition(.numericText(value: Double(recorder.segmentsThisSession)))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    quickRecap(15)
                } label: {
                    Label("最近 15 分鐘重點", systemImage: "sparkles")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                Menu {
                    Button("最近 5 分鐘") { quickRecap(5) }
                    Button("最近 30 分鐘") { quickRecap(30) }
                    Button("最近 1 小時") { quickRecap(60) }
                } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.headline).padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("其他時間範圍的重點")
            }

            HStack(spacing: 10) {
                if recorder.mode == .lecture {
                    Button {
                        router.tab = .lecture
                    } label: {
                        Label("看即時翻譯", systemImage: "captions.bubble").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                }
                if recorder.state == .interrupted || recorder.state == .paused {
                    Button {
                        Task { await recorder.resume() }
                    } label: {
                        Label("繼續", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button {
                        recorder.pause()
                    } label: {
                        Label("暫停", systemImage: "pause.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                }
                Button(role: .destructive) {
                    Task { await recorder.stop() }
                } label: {
                    Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glass)
            }
        }
    }

    @Environment(QuickRecap.self) private var quick

    private func quickRecap(_ minutes: Int) {
        Haptics.tap()
        router.showQuickRecap = true
        Task { await quick.run(minutes: minutes) }
    }

    private var statusTitle: String {
        switch recorder.state {
        case .starting: "準備中…"
        case .interrupted: "錄音被中斷"
        case .paused: "已暫停"
        default: recorder.mode == .lecture ? "課堂模式錄音中" : "錄音中"
        }
    }

    private var nextScheduleText: String? {
        let enabled = settings.schedules.filter(\.enabled)
        guard !enabled.isEmpty else { return nil }
        if let active = settings.activeSchedule() {
            return "現在是「\(active.rule.name)」時段（到 \(active.end.hm)）"
        }
        return "排程：" + enabled.map { "\($0.name) \($0.weekdayText) \($0.timeRangeText)" }.joined(separator: "；")
    }

    private func start(_ duration: TimeInterval?) {
        error = nil
        Task {
            do {
                try await recorder.start(mode: .allDay, duration: duration, source: .manual)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// 一天的內容：Recap 卡片＋時間軸。今天與歷史共用。
struct DayContentView: View {
    let dayKey: String
    var isToday = false
    @Environment(RecapStore.self) private var store
    @Environment(ProcessingQueue.self) private var queue

    var body: some View {
        content
            // 螢幕感知：Siri 知道「今天／這天的 Recap」是哪一天
            .userActivity(SiriScreen.dayActivity) { activity in
                activity.title = store.day(dayKey).recap?.title ?? dayKey
                activity.appEntityIdentifier = EntityIdentifier(for: DayRecapEntity.self, identifier: dayKey)
            }
    }

    @ViewBuilder
    private var content: some View {
        let record = store.day(dayKey)
        VStack(spacing: 16) {
            recapCard(record)
            if let status = queue.statusText {
                HStack(spacing: 8) {
                    ThinkingIndicator(activity: .init(status: status))
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .transition(.opacity)
            }
            timeline(record)
        }
        .animation(.smooth, value: queue.statusText)
    }

    @ViewBuilder
    private func recapCard(_ record: DayRecord) -> some View {
        if let muse = record.claudeRecap, !muse.isEmpty {
            // Muse 的整理就是這天的 Recap
            MuseNotesCard(label: "Recap・Muse 整理", raw: muse,
                          sheetTitle: record.date.formatted(.dateTime.month().day().weekday()) + " Recap")
        } else {
            appRecapCard(record)
        }
    }

    private func appRecapCard(_ record: DayRecord) -> some View {
        Card {
            HStack {
                Label("Recap", systemImage: "sparkles").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                Spacer()
                if !record.segments.isEmpty {
                    NavigationLink(value: AskRoute(scope: .day(dayKey))) {
                        Label("追問", systemImage: "questionmark.bubble").font(.footnote)
                    }
                    .buttonStyle(.glass)
                    if !AIConfig.usesMuse {
                        Button {
                            Haptics.tap()
                            queue.regenerateRecap(dayKey)
                        } label: {
                            Label(record.recap == nil ? "整理" : "重新整理", systemImage: "arrow.clockwise")
                                .font(.footnote)
                        }
                        .buttonStyle(.glass)
                        .disabled(queue.isRunning)
                    }
                }
            }
            if let recap = record.recap {
                Text(recap.title).font(.title2.bold())
                Text(recap.overview).font(.body)
                if !recap.highlights.isEmpty {
                    BulletList(items: recap.highlights)
                }
                if !recap.todos.isEmpty {
                    Divider()
                    Text("待辦").font(.subheadline.weight(.semibold))
                    TodoList(items: recap.todos, source: "Recap \(record.date.formatted(.dateTime.month().day())) 錄音")
                }
                Text("整理於 \(recap.generatedAt.hm)・\(recap.sourceCount) 段內容\(record.recapDirty ? "・有新內容" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            } else if AIConfig.usesMuse, !record.segments.isEmpty || !record.lectures.isEmpty {
                Text("逐字稿會同步給 Muse，整理好的 Recap 會自動出現在這裡。").font(.subheadline).foregroundStyle(.secondary)
            } else if record.segments.isEmpty {
                Text(isToday ? "今天還沒有錄音。開始錄音後，App 會每 5 分鐘切一段、在背景轉成文字，再用 \(AIConfig.engineName) 整理成今日 Recap。" : "這天沒有內容。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(pendingText(record)).font(.subheadline).foregroundStyle(.secondary)
            }
            if queue.readiness != .available {
                Label(queue.readiness.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func pendingText(_ record: DayRecord) -> String {
        let waitingText = record.segments.filter { $0.status == .recorded }.count
        let waitingSummary = record.segments.filter { $0.status == .transcribed }.count
        var parts: [String] = []
        if waitingText > 0 { parts.append("\(waitingText) 段等待轉文字") }
        if waitingSummary > 0 { parts.append("\(waitingSummary) 段等待摘要") }
        if parts.isEmpty { return "內容整理好後會在這裡出現今日 Recap。" }
        return parts.joined(separator: "、") + "。整理完會自動產生 Recap。"
    }

    @ViewBuilder
    private func timeline(_ record: DayRecord) -> some View {
        let items = timelineItems(record)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("時間軸").font(.headline)
                    Spacer()
                    let silent = record.segments.filter { $0.status == .silent }.count
                    if silent > 0 { Text("\(silent) 段安靜已略過").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.bottom, 8)
                ForEach(items) { item in
                    switch item {
                    case .segment(let segment):
                        NavigationLink(value: SegmentRoute(dayKey: dayKey, id: segment.id)) {
                            SegmentRow(segment: segment)
                        }
                        .buttonStyle(.plain)
                        .appEntityIdentifier(EntityIdentifier(for: RecordingSegmentEntity.self, identifier: RecordingSegmentEntity.makeID(dayKey: dayKey, segmentID: segment.id)))
                    case .lecture(let lecture):
                        NavigationLink(value: LectureRoute(id: lecture.id)) {
                            LectureRow(lecture: lecture)
                        }
                        .buttonStyle(.plain)
                        .appEntityIdentifier(EntityIdentifier(for: LectureEntity.self, identifier: lecture.id))
                    }
                    Divider().padding(.leading, 64)
                }
            }
        }
    }

    private func timelineItems(_ record: DayRecord) -> [TimelineItem] {
        // 課堂只放在課堂頁
        record.spokenSegments.map(TimelineItem.segment).sorted { $0.date > $1.date }
    }
}

enum TimelineItem: Identifiable {
    case segment(Segment)
    case lecture(Lecture)

    var id: UUID {
        switch self {
        case .segment(let s): s.id
        case .lecture(let l): l.id
        }
    }

    var date: Date {
        switch self {
        case .segment(let s): s.start
        case .lecture(let l): l.start
        }
    }
}

struct SegmentRoute: Hashable { let dayKey: String; let id: UUID }
struct LectureRoute: Hashable { let id: UUID }
struct DayRoute: Hashable { let dayKey: String }
struct AskRoute: Hashable { let scope: AskScope }

extension View {
    func navigationDestinations() -> some View {
        self
            .navigationDestination(for: SegmentRoute.self) { SegmentDetailView(route: $0) }
            .navigationDestination(for: LectureRoute.self) { LectureDetailView(id: $0.id) }
            .navigationDestination(for: DayRoute.self) { DayDetailView(dayKey: $0.dayKey) }
            .navigationDestination(for: AskRoute.self) { AskView(initialScope: $0.scope) }
    }
}

struct SegmentRow: View {
    let segment: Segment
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(segment.start.hm)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if let title = segment.title, !title.isEmpty {
                    Text(title).font(.body.weight(.semibold))
                    if let first = segment.points.first {
                        Text(first).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                } else if let transcript = segment.transcript, !transcript.isEmpty {
                    Text(transcript.replacingOccurrences(of: "\n", with: " ")).font(.subheadline).lineLimit(2)
                    Text(segment.status.label).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(segment.status.label).font(.subheadline).foregroundStyle(segment.status == .failed ? .red : .secondary)
                }
                if !segment.todos.isEmpty {
                    Label(segment.todos.joined(separator: "、"), systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}

struct LectureRow: View {
    let lecture: Lecture
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(lecture.start.hm)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Label(lecture.displayTitle, systemImage: "graduationcap.fill").font(.body.weight(.semibold))
                if let overview = lecture.summary?.overview, !overview.isEmpty {
                    Text(overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(lecture.end == nil ? "上課中" : (lecture.needsSummary ? "等待整理重點" : "\(lecture.lines.count) 句"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}
