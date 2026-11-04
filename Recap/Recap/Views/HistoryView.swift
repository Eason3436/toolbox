import SwiftUI

struct HistoryView: View {
    @Environment(RecapStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                if store.dayKeys.isEmpty {
                    ContentUnavailableView("還沒有紀錄", systemImage: "calendar", description: Text("開始錄音後，每天的 Recap 會出現在這裡。"))
                }
                ForEach(store.dayKeys, id: \.self) { key in
                    let record = store.day(key)
                    NavigationLink(value: DayRoute(dayKey: key)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.date.formatted(.dateTime.month().day().weekday(.wide)))
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(record.recap?.title ?? "尚未整理").font(.headline)
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
            .navigationTitle("歷史")
            .navigationDestinations()
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
    @Environment(RecapStore.self) private var store
    @Environment(ProcessingQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let segment = store.day(route.dayKey).segments.first(where: { $0.id == route.id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        Text("\(segment.start.hm)–\(segment.end.hm)・\(segment.duration.clockText)")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(segment.title ?? segment.status.label).font(.title3.bold())
                        if !segment.points.isEmpty { BulletList(items: segment.points) }
                        if !segment.todos.isEmpty {
                            BulletList(items: segment.todos, symbol: "checkmark.circle", tint: .green)
                        }
                        if let error = segment.error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    if let file = segment.audioFile {
                        Card { AudioPlayerView(url: store.audioURL(file)) }
                    }
                    Card {
                        Text("逐字稿").font(.headline)
                        if let transcript = segment.transcript, !transcript.isEmpty {
                            Text(transcript).textSelection(.enabled)
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
                            store.updateSegment(segment.id, in: route.dayKey) { $0.status = .transcribed }
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
        for lecture in record.lectures {
            out += "- **\(lecture.start.hm)** 課堂：\(lecture.displayTitle)\n"
        }
        return out
    }

    static func lecture(_ lecture: Lecture) -> String {
        var out = "# \(lecture.displayTitle)\n\n\(lecture.start.formatted(date: .abbreviated, time: .shortened))\n\n"
        if let s = lecture.summary, !s.title.isEmpty {
            out += "## 重點\n\n\(s.overview)\n\n" + s.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
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
