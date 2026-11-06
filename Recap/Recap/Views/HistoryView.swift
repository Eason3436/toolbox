import AppIntents
import SwiftUI

struct HistoryView: View {
    @Environment(RecapStore.self) private var store
    @State private var category = Category.days
    @State private var path = NavigationPath()
    @State private var importing = false

    enum Category: String, CaseIterable, Identifiable {
        case days = "每日紀錄"
        case lectures = "課堂"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Picker("分類", selection: $category) {
                    ForEach(Category.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                switch category {
                case .days: dayRows
                case .lectures: lectureRows
                }
            }
            .navigationTitle("歷史")
            .toolbar {
                if category == .lectures {
                    Button("匯入錄音檔", systemImage: "waveform.badge.plus") { importing = true }
                }
            }
            .sheet(isPresented: $importing) {
                ImportAudioView { id in path.append(LectureRoute(id: id)) }
            }
            .sensoryFeedback(.selection, trigger: category)
            .navigationDestinations()
        }
    }

    @ViewBuilder
    private var dayRows: some View {
        if store.dayKeys.isEmpty {
            ContentUnavailableView("還沒有紀錄", systemImage: "calendar", description: Text("開始錄音後，每天的 Recap 會出現在這裡。"))
        }
        ForEach(store.dayKeys, id: \.self) { key in
            let record = store.day(key)
            NavigationLink(value: DayRoute(dayKey: key)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.date.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(record.recap?.title ?? (record.spokenSegments.isEmpty ? "沒有全天錄音" : "尚未整理")).font(.headline)
                    HStack(spacing: 12) {
                        Label("\(record.spokenSegments.count) 段", systemImage: "waveform")
                        if !record.lectures.isEmpty {
                            Label("\(record.lectures.count) 堂課", systemImage: "graduationcap")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .swipeActions {
                Button("刪除", role: .destructive) { store.deleteDay(key) }
            }
        }
    }

    @ViewBuilder
    private var lectureRows: some View {
        let lectures = store.allLectures
        if lectures.isEmpty {
            ContentUnavailableView("還沒有課堂紀錄", systemImage: "graduationcap",
                                   description: Text("在「課堂」分頁開始上課，或按右上角匯入錄音檔。"))
        }
        ForEach(lectures) { lecture in
            NavigationLink(value: LectureRoute(id: lecture.id)) {
                HStack(spacing: 12) {
                    Image(systemName: lecture.subject?.symbol ?? "graduationcap")
                        .font(.title3).foregroundStyle(.tint).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(lecture.displayTitle).font(.headline).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(lecture.start.formatted(.dateTime.month().day().weekday().hour().minute()))
                            if let end = lecture.end {
                                Text("・\(Int(end.timeIntervalSince(lecture.start) / 60)) 分鐘")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if lecture.needsTranscription {
                            Label("轉文字中", systemImage: "hourglass").font(.caption2).foregroundStyle(.orange)
                        } else if lecture.richNotes != nil {
                            Label("有詳細筆記", systemImage: "doc.richtext").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .appEntityIdentifier(EntityIdentifier(for: LectureEntity.self, identifier: lecture.id))
            .swipeActions {
                Button("刪除", role: .destructive) { store.deleteLecture(lecture) }
            }
        }
    }
}

struct DayDetailView: View {
    let dayKey: String
    @Environment(RecapStore.self) private var store

    var body: some View {
        ScrollView {
            DayContentView(dayKey: dayKey, isToday: dayKey == DayKey.today)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .navigationTitle(store.day(dayKey).date.formatted(.dateTime.month().day().weekday()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: MarkdownExport.day(store.day(dayKey))) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }
}

struct SegmentDetailView: View {
    let route: SegmentRoute
    @State private var showRaw = false
    @Environment(RecapStore.self) private var store
    @Environment(ProcessingQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .userActivity(SiriScreen.segmentActivity) { activity in
                activity.title = store.day(route.dayKey).segments.first(where: { $0.id == route.id })?.title ?? "錄音片段"
                activity.appEntityIdentifier = EntityIdentifier(for: RecordingSegmentEntity.self, identifier: RecordingSegmentEntity.makeID(dayKey: route.dayKey, segmentID: route.id))
            }
    }

    @ViewBuilder
    private var content: some View {
        if let segment = store.day(route.dayKey).segments.first(where: { $0.id == route.id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        Text("\(segment.start.hm)–\(segment.end.hm)・\(segment.duration.clockText)")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(segment.title ?? segment.status.label).font(.title3.bold())
                        if !segment.points.isEmpty { BulletList(items: segment.points) }
                        if !segment.todos.isEmpty {
                            TodoList(items: segment.todos, source: "Recap 錄音 \(segment.start.formatted(date: .abbreviated, time: .shortened))")
                        }
                        if let error = segment.error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    if let file = segment.audioFile {
                        Card { AudioPlayerView(url: store.audioURL(file)) }
                    }
                    Card {
                        HStack {
                            Text("逐字稿").font(.headline)
                            Spacer()
                            if segment.correctedTranscript != nil {
                                Toggle("原始辨識", isOn: $showRaw).fixedSize().font(.footnote)
                            }
                        }
                        if let transcript = showRaw ? segment.transcript : segment.bestTranscript, !transcript.isEmpty {
                            Text(transcript).textSelection(.enabled)
                            if segment.correctedTranscript != nil, !showRaw {
                                Label("已用 AI 校正錯字", systemImage: "wand.and.sparkles").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(segment.status.label).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle(segment.start.hm)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    if segment.audioFile != nil {
                        Button("重新轉文字", systemImage: "text.bubble") {
                            store.updateSegment(segment.id, in: route.dayKey) { $0.status = .recorded; $0.title = nil; $0.points = []; $0.todos = [] }
                            queue.kick(summaries: true)
                        }
                    }
                    if segment.hasText {
                        Button("重新摘要", systemImage: "sparkles") {
                            store.updateSegment(segment.id, in: route.dayKey) { $0.status = .transcribed; $0.correctedTranscript = nil }
                            queue.kick(summaries: true)
                        }
                    }
                    Button("刪除這段", systemImage: "trash", role: .destructive) {
                        store.deleteSegment(segment)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        } else {
            ContentUnavailableView("找不到這段", systemImage: "questionmark")
        }
    }
}

/// 匯出成 Markdown 文字（分享用）。
enum MarkdownExport {
    static func day(_ record: DayRecord) -> String {
        var out = "# \(record.date.formatted(.dateTime.year().month().day().weekday(.wide))) Recap\n\n"
        if let recap = record.recap {
            out += "## \(recap.title)\n\n\(recap.overview)\n\n"
            out += recap.highlights.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            if !recap.todos.isEmpty { out += "### 待辦\n" + recap.todos.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n\n" }
        }
        out += "## 時間軸\n\n"
        for segment in record.spokenSegments {
            out += "- **\(segment.start.hm)** \(segment.title ?? "")：\(segment.points.joined(separator: "；"))\n"
        }
        return out
    }

    static func lecture(_ lecture: Lecture) -> String {
        var out = "# \(lecture.displayTitle)\n\n\(lecture.start.formatted(date: .abbreviated, time: .shortened))\n\n"
        if let s = lecture.summary, !s.title.isEmpty {
            out += "## 重點\n\n\(s.overview)\n\n" + s.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            if let exam = s.examPoints, !exam.isEmpty { out += "## \(lecture.subject?.isSeminar == true ? "講者強調" : "老師說會考")\n\n" + exam.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if !s.terms.isEmpty { out += "## 術語\n\n" + s.terms.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if !s.todos.isEmpty { out += "## 提醒\n\n" + s.todos.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n\n" }
        }
        out += "## 逐字稿\n\n"
        for line in lecture.lines {
            out += "[\(line.offset.clockText)] \(line.source)\n"
            if let t = line.translation, !t.isEmpty { out += "> \(t)\n" }
            out += "\n"
        }
        return out
    }
}
