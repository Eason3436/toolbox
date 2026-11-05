import AppIntents
import SwiftUI
import Translation

/// 課堂分頁：上課中顯示即時字幕，否則顯示開始畫面與過去的課。
struct LectureHomeView: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.lecturePath) {
            Group {
                if recorder.mode == .lecture, recorder.isActive, let session = recorder.lecture {
                    LectureLiveView(session: session)
                        .userActivity(SiriScreen.lectureActivity) { activity in
                            activity.title = session.lecture.displayTitle
                            activity.appEntityIdentifier = EntityIdentifier(for: LectureEntity.self, identifier: session.lecture.id)
                        }
                } else {
                    LectureStartView()
                }
            }
            .navigationDestinations()
        }
    }
}

struct TargetLanguage: Identifiable, Hashable {
    let id: String
    let name: String
    static let all = [
        TargetLanguage(id: "zh-Hant-TW", name: "繁體中文"),
        TargetLanguage(id: "zh-Hans-CN", name: "簡體中文"),
        TargetLanguage(id: "en-US", name: "英文"),
        TargetLanguage(id: "ja-JP", name: "日文"),
    ]
}

struct LectureStartView: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(AppSettings.self) private var settings
    @Environment(RecapStore.self) private var store
    @State private var locales: [Locale] = []
    @State private var translationStatus: LanguageAvailability.Status?
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var error: String?
    @State private var starting = false

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("中文課只錄音，下課後才轉成文字並用 \(AIConfig.engineName) 整理重點、摘要和老師提醒的事項，比較省電。英文等非中文授課會即時顯示字幕和翻譯。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                subjectRow
                NavigationLink {
                    TimetableView()
                } label: {
                    LabeledContent("課表", value: settings.timetable.isEmpty ? "未設定" : "\(settings.timetable.count) 節")
                }
            }
            Section {
                Toggle("非中文授課（即時字幕與翻譯）", isOn: foreignBinding)
                if isForeign {
                    Picker("上課語言", selection: $settings.lectureSourceLocale) {
                        if locales.isEmpty { Text(settings.lectureSourceLocale).tag(settings.lectureSourceLocale) }
                        ForEach(locales.filter { !$0.identifier.hasPrefix("zh") }, id: \.identifier) { locale in
                            Text(SpeechSupport.displayName(locale)).tag(locale.identifier)
                        }
                    }
                    Picker("翻譯成", selection: $settings.translationTarget) {
                        ForEach(TargetLanguage.all) { Text($0.name).tag($0.id) }
                    }
                    translationRow
                }
            }
            Section {
                Button {
                    start()
                } label: {
                    HStack {
                        Spacer()
                        if starting { ProgressView() } else { Label("開始上課", systemImage: "record.circle").font(.headline) }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .disabled(starting)
                if recorder.isActive, recorder.mode == .allDay {
                    Text("目前在全天錄音，開始上課會先停止全天錄音。").font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section("過去的課") {
                let lectures = store.allLectures
                if lectures.isEmpty {
                    Text("還沒有上過課").foregroundStyle(.secondary)
                }
                ForEach(lectures) { lecture in
                    NavigationLink(value: LectureRoute(id: lecture.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lecture.displayTitle).font(.headline)
                            Text("\(lecture.start.formatted(date: .abbreviated, time: .shortened))・\(lecture.lines.count) 句")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .appEntityIdentifier(EntityIdentifier(for: LectureEntity.self, identifier: lecture.id))
                }
                .onDelete { offsets in
                    for index in offsets { store.deleteLecture(lectures[index]) }
                }
            }
        }
        .navigationTitle("課堂模式")
        .sensoryFeedback(.selection, trigger: settings.lectureSourceLocale)
        .sensoryFeedback(.selection, trigger: settings.translationTarget)
        .sensoryFeedback(.selection, trigger: settings.lectureForeign)
        .task {
            locales = await SpeechSupport.supportedLocales().sorted { $0.identifier < $1.identifier }
            await refreshStatus()
        }
        .onChange(of: settings.lectureSourceLocale) { Task { await refreshStatus() } }
        .onChange(of: settings.translationTarget) { Task { await refreshStatus() } }
        .translationTask(downloadConfig) { session in
            do {
                try await session.prepareTranslation()
            } catch {
                self.error = "翻譯語言下載失敗：\(error.localizedDescription)"
            }
            await refreshStatus()
        }
    }

    /// 現在課表上的那節課
    private var currentEntry: TimetableEntry? { settings.timetableEntry() }

    /// 課表上是英文課就自動開即時字幕；沒有課表時看開關
    private var isForeign: Bool {
        if let entry = currentEntry { return entry.subject == .english }
        return settings.lectureForeign
    }

    private var foreignBinding: Binding<Bool> {
        Binding { isForeign } set: { settings.lectureForeign = $0 }
    }

    @ViewBuilder
    private var subjectRow: some View {
        if let entry = currentEntry {
            Label("依課表：\(entry.title)（\(entry.timeText)）", systemImage: entry.subject.symbol)
        } else {
            Label("科目：下課後由 AI 自動判斷", systemImage: "wand.and.stars")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var translationRow: some View {
        switch translationStatus {
        case .installed:
            Label("翻譯語言已下載，可離線即時翻譯", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
        case .supported:
            VStack(alignment: .leading, spacing: 6) {
                Label("要先下載翻譯語言（只需一次），不然會改用 Apple Intelligence 翻譯，比較慢。", systemImage: "arrow.down.circle")
                    .font(.footnote).foregroundStyle(.orange)
                Button("下載翻譯語言") {
                    downloadConfig = TranslationSession.Configuration(
                        source: Locale(identifier: settings.lectureSourceLocale).language,
                        target: Locale.Language(identifier: settings.translationTarget)
                    )
                }
            }
        case .unsupported:
            Label("系統翻譯不支援這組語言，會改用 Apple Intelligence 翻譯。", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    private func refreshStatus() async {
        translationStatus = await TranslationSupport.status(sourceLocale: settings.lectureSourceLocale, target: settings.translationTarget)
    }

    private func start() {
        error = nil
        starting = true
        Task {
            defer { starting = false }
            do {
                try await recorder.start(mode: .lecture, source: .manual)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// 上課中：即時字幕＋翻譯。
struct LectureLiveView: View {
    let session: LectureSession
    @Environment(RecordingController.self) private var recorder
    @Environment(Router.self) private var router
    @Environment(QuickRecap.self) private var quick
    @Environment(AppSettings.self) private var settings
    @State private var follow = true

    private var noTranslation: Bool { session.translatorName == "不需翻譯" }

    var body: some View {
        @Bindable var settings = settings
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.lecture.lines) { line in
                        LineView(line: line, showSource: settings.lectureShowSource || noTranslation, sourceIsMain: noTranslation)
                            .id(line.id)
                    }
                    if !session.volatileText.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if settings.lectureShowSource || noTranslation {
                                Text(session.volatileText).font(noTranslation ? .title3 : .subheadline).foregroundStyle(.tertiary)
                            }
                            if !session.volatileTranslation.isEmpty {
                                Text(session.volatileTranslation).font(.title3).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !session.isLive {
                        ContentUnavailableView {
                            Label(session.lecture.subject.map { $0 == .general ? "錄音中" : "\($0.title)課錄音中" } ?? "錄音中", systemImage: "waveform")
                        } description: {
                            Text("中文課只錄音，比較省電。下課後會轉成文字，並整理上課重點、摘要和老師提醒的事項。")
                        }
                    } else if session.lecture.lines.isEmpty && session.volatileText.isEmpty {
                        ContentUnavailableView("正在聽…", systemImage: "ear", description: Text("老師開始說話後，原文和翻譯會出現在這裡。第一次使用某個語言時要先下載語音模型。"))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .onChange(of: session.lecture.lines.count) {
                if follow { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: session.volatileText) {
                if follow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: recorder.state == .interrupted ? "pause.circle.fill" : "record.circle")
                            .foregroundStyle(recorder.state == .interrupted ? .orange : .red)
                        if let started = recorder.startedAt {
                            Text(started, style: .timer).font(.headline.monospacedDigit())
                        }
                    }
                    Text(session.translatorName).font(.caption2).foregroundStyle(.secondary)
                }
                LevelMeter(level: recorder.level).frame(width: 60)
                Spacer()
                if recorder.state == .interrupted || recorder.state == .paused {
                    Button("繼續") { Task { await recorder.resume() } }.buttonStyle(.glassProminent)
                } else {
                    Button { recorder.pause() } label: { Image(systemName: "pause.fill").padding(.vertical, 4) }
                        .buttonStyle(.glass)
                }
                Button(role: .destructive) {
                    Task { await recorder.stop() }
                } label: {
                    Label("下課", systemImage: "stop.fill").padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 12)
        }
        .navigationTitle("上課中")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                router.showQuickRecap = true
                Task { await quick.run(minutes: 15) }
            } label: {
                Label("最近 15 分鐘重點", systemImage: "sparkles")
            }
            Menu {
                Toggle("顯示原文", isOn: $settings.lectureShowSource)
                Toggle("自動捲到最新", isOn: $follow)
            } label: {
                Image(systemName: "textformat")
            }
        }
    }
}

private struct LineView: View {
    let line: LiveLine
    let showSource: Bool
    var sourceIsMain = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showSource {
                Text(line.source).font(sourceIsMain ? .title3 : .subheadline).foregroundStyle(sourceIsMain ? .primary : .secondary)
            }
            if sourceIsMain {
                EmptyView()
            } else if let t = line.translation {
                if !t.isEmpty { Text(t).font(.title3) }
            } else {
                Text("翻譯中…").font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// 課後：重點、術語、錄音、雙語逐字稿。
struct LectureDetailView: View {
    let id: UUID
    @Environment(RecapStore.self) private var store
    @Environment(ProcessingQueue.self) private var queue
    @State private var renaming = false
    @State private var newName = ""
    @State private var showSource = true
    @State private var showingNotes = false

    var body: some View {
        if let lecture = store.lecture(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    richNotesCard(lecture)
                    if let notes = lecture.claudeNotes { ClaudeNotesCard(title: "Claude 的課堂筆記", markdown: notes) }
                    summaryCard(lecture)
                    if !lecture.audioParts.isEmpty {
                        Card {
                            Text("錄音").font(.headline)
                            ForEach(Array(lecture.audioParts.enumerated()), id: \.offset) { index, part in
                                AudioPlayerView(url: store.audioURL(part.file), title: lecture.audioParts.count > 1 ? "第 \(index + 1) 段・\(part.start.hm)" : nil)
                            }
                        }
                    }
                    if let refined = lecture.refinedTranscript, !refined.isEmpty {
                        Card {
                            DisclosureGroup {
                                Text(refined).font(.subheadline).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Label("中英合併逐字稿", systemImage: "text.badge.checkmark").font(.headline)
                            }
                        }
                    }
                    Card {
                        HStack {
                            Text("逐字稿（\(lecture.lines.count) 句）").font(.headline)
                            Spacer()
                            Toggle("原文", isOn: $showSource).fixedSize().font(.footnote)
                        }
                        ForEach(lecture.lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.offset.clockText).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                if showSource { Text(line.source).font(.subheadline).foregroundStyle(.secondary) }
                                if let t = line.translation, !t.isEmpty { Text(t) }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle(lecture.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            // 螢幕感知：Siri 知道「這堂課」是哪一堂
            .userActivity(SiriScreen.lectureActivity) { activity in
                activity.title = lecture.displayTitle
                activity.appEntityIdentifier = EntityIdentifier(for: LectureEntity.self, identifier: lecture.id)
            }
            .toolbar {
                NavigationLink(value: AskRoute(scope: .lecture(lecture.id))) { Image(systemName: "questionmark.bubble") }
                ShareLink(item: MarkdownExport.lecture(lecture)) { Image(systemName: "square.and.arrow.up") }
                Menu {
                    Button("重新命名", systemImage: "pencil") { newName = lecture.name ?? lecture.displayTitle; renaming = true }
                    Picker(selection: Binding(get: { lecture.subject ?? .general }, set: { value in
                        var updated = lecture
                        updated.subject = value
                        store.upsertLecture(updated)
                        Haptics.selection()
                    })) {
                        ForEach(SchoolSubject.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    } label: {
                        Label("科目：\(lecture.subject?.title ?? "未判斷")", systemImage: "books.vertical")
                    }
                    .pickerStyle(.menu)
                    Button("重新整理重點", systemImage: "sparkles") { queue.resummarizeLecture(lecture.id) }
                    if AIConfig.usesGemini {
                        Button("重新製作詳細筆記", systemImage: "doc.richtext") { queue.regenerateRichNotes(lecture.id) }
                    }
                } label: { Image(systemName: "ellipsis") }
            }
            .alert("課堂名稱", isPresented: $renaming) {
                TextField("例如：經濟學原理", text: $newName)
                Button("儲存") {
                    var updated = lecture
                    updated.name = newName
                    store.upsertLecture(updated)
                }
                Button("取消", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("找不到這堂課", systemImage: "questionmark")
        }
    }

    @ViewBuilder
    private func richNotesCard(_ lecture: Lecture) -> some View {
        if let html = lecture.richNotes, !html.isEmpty {
            Button {
                Haptics.tap()
                showingNotes = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("詳細課程筆記").font(.headline).foregroundStyle(.primary)
                        Text("流程、重點、會考、補充、事實查核、單字表").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingNotes) { RichNotesSheet(lecture: lecture, html: html) }
        } else if AIConfig.usesGemini, lecture.summary != nil {
            Card {
                if let error = lecture.richNotesError {
                    Label("課程筆記失敗：\(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                    Button("再試一次") { queue.regenerateRichNotes(lecture.id) }.buttonStyle(.glass)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Gemini 正在製作詳細課程筆記…").foregroundStyle(.secondary)
                    }
                    Button("現在製作") { queue.kick(summaries: true) }.buttonStyle(.glass)
                }
            }
        }
    }

    private func summaryCard(_ lecture: Lecture) -> some View {
        Card {
            HStack(spacing: 6) {
                if let subject = lecture.subject, subject != .general {
                    Label(subject.title, systemImage: subject.symbol)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.tint.opacity(0.12), in: Capsule())
                }
                Text("\(lecture.start.formatted(date: .abbreviated, time: .shortened))\(lecture.end.map { "–\($0.hm)" } ?? "")")
            }
            .font(.subheadline).foregroundStyle(.secondary)
            if let s = lecture.summary, !s.title.isEmpty {
                Text(s.title).font(.title2.bold())
                Text(s.overview)
                if !s.keyPoints.isEmpty {
                    Text("課堂重點").font(.headline).padding(.top, 4)
                    BulletList(items: s.keyPoints)
                }
                if let exam = s.examPoints, !exam.isEmpty {
                    Label(lecture.subject?.isSeminar == true ? "講者強調" : "老師說會考", systemImage: "star.fill")
                        .font(.headline).foregroundStyle(.orange).padding(.top, 4)
                    BulletList(items: exam, symbol: "star", tint: .orange)
                }
                if !s.terms.isEmpty {
                    Text("術語").font(.headline).padding(.top, 4)
                    BulletList(items: s.terms, symbol: "character.book.closed", tint: .purple)
                }
                if !s.todos.isEmpty {
                    Text("作業與提醒").font(.headline).padding(.top, 4)
                    TodoList(items: s.todos, source: "Recap 課堂：\(lecture.displayTitle)")
                }
                NavigationLink(value: AskRoute(scope: .lecture(lecture.id))) {
                    Label("對這堂課追問", systemImage: "questionmark.bubble")
                }
                .buttonStyle(.glass)
                .padding(.top, 4)
            } else if let error = lecture.summaryError {
                Label("整理重點失敗：\(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("再試一次") { queue.resummarizeLecture(lecture.id) }.buttonStyle(.glass)
            } else if lecture.end == nil {
                Text("上課中，下課後會整理重點。").foregroundStyle(.secondary)
            } else if lecture.needsTranscription {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("下課了，正在把錄音轉成文字…").foregroundStyle(.secondary)
                }
                Button("現在整理") { queue.kick(summaries: true) }.buttonStyle(.glass)
            } else if lecture.lines.isEmpty {
                Text("這堂課沒有辨識到內容。").foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(queue.readiness == .available ? "正在整理重點…" : queue.readiness.message).foregroundStyle(.secondary)
                }
                Button("現在整理") { queue.kick(summaries: true) }.buttonStyle(.glass)
            }
        }
    }
}
