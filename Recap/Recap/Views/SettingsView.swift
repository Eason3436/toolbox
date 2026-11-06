import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RecapStore.self) private var store
    @Environment(ProcessingQueue.self) private var queue

    private var aiModelLabel: String {
        switch settings.aiProvider {
        case .gemini: settings.geminiAPIKey.isEmpty ? "Gemini（未設定 Key）" : "Gemini"
        case .muse: settings.canSync ? "Muse" : "Muse（未連線）"
        case .apple: "Apple Intelligence"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AIProviderView()
                    } label: {
                        SettingsRow(title: "整理筆記與摘要", detail: aiModelLabel, symbol: "sparkles", tint: .orange)
                    }
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        SettingsRow(title: "Muse 同步", detail: settings.canSync ? "已連線" : "未連線", symbol: "arrow.triangle.2.circlepath", tint: .purple)
                    }
                    NavigationLink {
                        WhisperSettingsView()
                    } label: {
                        SettingsRow(title: "Whisper 補強辨識", detail: settings.canUseWhisper ? "每天 \(settings.whisperDailyMinutes) 分鐘" : "關閉", symbol: "waveform.badge.magnifyingglass", tint: .teal)
                    }
                } header: {
                    Text("AI")
                } footer: {
                    if ModelReadiness.current != .available {
                        Label(ModelReadiness.current.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }

                Section("錄音與辨識") {
                    NavigationLink {
                        RecordingSettingsView()
                    } label: {
                        SettingsRow(title: "錄音與排程", detail: settings.schedules.contains(where: \.enabled) ? "有排程" : "手動", symbol: "record.circle", tint: .red)
                    }
                    NavigationLink {
                        RecognitionSettingsView()
                    } label: {
                        SettingsRow(title: "語音辨識", detail: Locale(identifier: "zh-Hant-TW").localizedString(forIdentifier: settings.transcriptionLocale) ?? settings.transcriptionLocale, symbol: "text.bubble", tint: .blue)
                    }
                    NavigationLink {
                        TimetableView()
                    } label: {
                        SettingsRow(title: "課表", detail: settings.timetable.isEmpty ? "未設定" : "\(settings.timetable.count) 節", symbol: "calendar.badge.clock", tint: .green)
                    }
                }

                Section("資料") {
                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        SettingsRow(title: "儲存空間", detail: ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file), symbol: "internaldrive", tint: .gray)
                    }
                    Button {
                        queue.kick(summaries: true)
                    } label: {
                        SettingsRow(title: queue.isRunning ? "整理中…" : "現在整理全部", detail: nil, symbol: "arrow.clockwise", tint: .indigo)
                    }
                    .disabled(queue.isRunning)
                }

                Section {
                    NavigationLink {
                        ChangelogView()
                    } label: {
                        SettingsRow(title: "更新日誌", detail: Changelog.entries.first.map { Changelog.dateText($0.date) }, symbol: "list.bullet.rectangle", tint: .pink)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("錄音時狀態列會亮橘色麥克風燈號，這是系統規定，App 無法隱藏。整天收音很耗電，建議放桌上或接電源。")
                        Text("Recap \(Changelog.appVersion)")
                    }
                }
            }
            .navigationTitle("設定")
        }
    }
}

/// 設定首頁的一列：彩色圖示＋標題＋目前狀態
struct SettingsRow: View {
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: .rect(cornerRadius: 8))
            Text(title).foregroundStyle(.primary)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// 錄音與排程
struct RecordingSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var editing: ScheduleRule?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach(settings.schedules) { rule in
                    Button { editing = rule } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name).foregroundStyle(.primary)
                                Text("\(rule.weekdayText) \(rule.timeRangeText)・\(rule.mode.title)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(rule.enabled ? Color.accentColor : .secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    settings.schedules.remove(atOffsets: offsets)
                    AppModel.shared.schedulesChanged()
                }
                Button("新增排程", systemImage: "plus") { editing = ScheduleRule() }
                Toggle("開始時間到了發通知", isOn: $settings.scheduleNotifications)
                    .onChange(of: settings.scheduleNotifications) { AppModel.shared.schedulesChanged() }
                Toggle("時段內打開 App 自動開始", isOn: $settings.autoStartInSchedule)
                NavigationLink("設定捷徑自動化（全自動）") { ShortcutsGuideView() }
            } header: {
                Text("排程")
            } footer: {
                Text("iOS 不允許 App 自己在背景定時打開麥克風：時間到了會發通知，點一下就開始；到了結束時間會自動停止。想完全自動，請用「捷徑自動化」。")
            }

            Section {
                Picker("每段長度", selection: $settings.segmentMinutes) {
                    Text("3 分鐘").tag(3)
                    Text("5 分鐘").tag(5)
                    Text("10 分鐘").tag(10)
                }
                Toggle("人聲加強（降低背景雜音）", isOn: $settings.voiceProcessing)
                Toggle("沒人說話時自動省電", isOn: $settings.autoPowerSave)
                if settings.autoPowerSave {
                    Picker("近距離說話判定", selection: $settings.powerSaveSensitivity) {
                        Text("要很近").tag(0)
                        Text("一般").tag(1)
                        Text("稍遠也算").tag(2)
                    }
                }
                Toggle("安靜的段落不轉文字", isOn: $settings.skipSilence)
            } header: {
                Text("收音")
            } footer: {
                Text("自動省電：連續 3 分鐘附近沒人說話就關掉人聲加強、改用較低位元率；有人靠近說話或老師開始講課就馬上恢復。")
            }
        }
        .navigationTitle("錄音與排程")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: settings.segmentMinutes)
        .sheet(item: $editing) { rule in
            ScheduleEditorView(rule: rule) { saved in
                if let index = settings.schedules.firstIndex(where: { $0.id == saved.id }) {
                    settings.schedules[index] = saved
                } else {
                    settings.schedules.append(saved)
                }
                AppModel.shared.schedulesChanged()
            }
        }
    }
}

/// 語音辨識
struct RecognitionSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var locales: [Locale] = []
    @State private var installed: Set<String> = []

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("辨識語言", selection: $settings.transcriptionLocale) {
                    if locales.isEmpty { Text(settings.transcriptionLocale).tag(settings.transcriptionLocale) }
                    ForEach(locales, id: \.identifier) { locale in
                        Text(SpeechSupport.displayName(locale) + (installed.contains(locale.identifier) ? " ✓" : ""))
                            .tag(locale.identifier)
                    }
                }
                Toggle("中英夾雜辨識", isOn: $settings.mixedLanguage)
                Toggle("高中上課用語與專有名詞", isOn: $settings.highSchoolMode)
                if !AIConfig.usesMuse {
                    Toggle("AI 校正逐字稿錯字", isOn: $settings.aiCorrection)
                }
            } footer: {
                Text("打勾代表語音模型已在手機上，之後完全離線。中英夾雜：中文和英文模型各聽一次再合併，英文術語不會變成中文諧音。")
            }
            Section {
                NavigationLink {
                    LearningMemoryView()
                } label: {
                    LabeledContent("學習記憶", value: settings.learningMemory ? "已記住 \(LearningMemory.shared.terms.count) 個詞" : "關閉")
                }
                NavigationLink {
                    VocabularyView()
                } label: {
                    LabeledContent("自訂詞彙", value: settings.vocabulary.isEmpty ? "未設定" : "\(settings.vocabulary.count) 個")
                }
            } footer: {
                Text("App 會記住你常出現的專有名詞，下次辨識更準；也可以自己加詞。")
            }
        }
        .navigationTitle("語音辨識")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: settings.transcriptionLocale)
        .task {
            locales = await SpeechSupport.supportedLocales().sorted { $0.identifier < $1.identifier }
            installed = Set(await SpeechSupport.installedLocales().map(\.identifier))
        }
    }
}

/// 儲存空間
struct StorageSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RecapStore.self) private var store
    @State private var usage: RecapStore.StorageUsage?
    @State private var cleanupMessage: String?
    @State private var confirmCleanup = false

    private struct Slice: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let color: Color
    }

    private var slices: [Slice] {
        guard let usage else { return [] }
        return [
            Slice(id: "allDay", title: "全天錄音", bytes: usage.allDayAudio, color: .blue),
            Slice(id: "lecture", title: "課堂錄音", bytes: usage.lectureAudio, color: .orange),
            Slice(id: "text", title: "文字與筆記", bytes: usage.text, color: .green),
            Slice(id: "memory", title: "學習記憶", bytes: usage.memory, color: .purple),
        ].filter { $0.bytes > 0 }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(usage.map { size($0.total) } ?? "計算中…")
                            .font(.title2.weight(.semibold).monospacedDigit())
                            .contentTransition(.numericText())
                        Text("已使用").foregroundStyle(.secondary)
                    }
                    UsageBar(slices: slices.map { ($0.bytes, $0.color) })
                        .frame(height: 14)
                    legend
                }
                .padding(.vertical, 6)
            }

            Section {
                Picker(selection: $settings.audioRetentionDays) {
                    Text("1 天").tag(1)
                    Text("3 天").tag(3)
                    Text("7 天").tag(7)
                    Text("14 天").tag(14)
                    Text("30 天").tag(30)
                    Text("永久").tag(0)
                } label: {
                    SettingsRow(title: "錄音檔保留", detail: nil, symbol: "clock.arrow.circlepath", tint: .blue)
                }
                Toggle(isOn: $settings.deleteAudioAfterTranscribe) {
                    SettingsRow(title: "轉好文字就刪音檔", detail: nil, symbol: "waveform.slash", tint: .orange)
                }
                ShareLink(item: allText, preview: SharePreview("Recap 文字紀錄")) {
                    SettingsRow(title: "匯出所有文字紀錄", detail: nil, symbol: "square.and.arrow.up", tint: .indigo)
                }
                Button {
                    confirmCleanup = true
                } label: {
                    SettingsRow(title: "清理過期錄音檔", detail: nil, symbol: "trash", tint: .red)
                }
                .disabled(settings.audioRetentionDays == 0)
            } footer: {
                if let cleanupMessage {
                    Text(cleanupMessage)
                } else {
                    Text("超過保留天數的錄音檔會自動刪除，只留下文字稿、翻譯和筆記，追問照樣能用。還沒轉成文字的錄音不會被刪。")
                }
            }
        }
        .navigationTitle("儲存空間")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: settings.audioRetentionDays)
        .confirmationDialog("刪除超過 \(settings.audioRetentionDays) 天的錄音檔？", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("刪除錄音檔", role: .destructive) { cleanup() }
        } message: {
            Text("文字稿和筆記會保留。")
        }
        .task { await refresh() }
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(slices) { slice in
                HStack(spacing: 6) {
                    Circle().fill(slice.color).frame(width: 8, height: 8)
                    Text(slice.title).foregroundStyle(.secondary)
                    Text(size(slice.bytes)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.footnote)
            }
        }
    }

    private var allText: String {
        store.dayKeys.map { MarkdownExport.day(store.day($0)) }.joined(separator: "\n\n---\n\n")
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func refresh() async {
        let value = await store.storageUsage()
        withAnimation(.smooth) { usage = value }
    }

    private func cleanup() {
        let n = store.purgeAudio(olderThan: settings.audioRetentionDays)
        Haptics.success()
        withAnimation(.smooth) {
            cleanupMessage = n == 0 ? "沒有過期的錄音檔。" : "刪除了 \(n) 個錄音檔，文字稿和筆記都還在。"
        }
        Task { await refresh() }
    }
}

/// 分段用量長條，段與段之間留細縫，像「設定 → 一般 → 儲存空間」。
struct UsageBar: View {
    let slices: [(Int64, Color)]

    var body: some View {
        GeometryReader { geo in
            let total = max(1, slices.reduce(0) { $0 + $1.0 })
            let gap: CGFloat = 2
            let usable = max(0, geo.size.width - gap * CGFloat(max(0, slices.count - 1)))
            HStack(spacing: gap) {
                if slices.isEmpty {
                    Rectangle().fill(.fill.tertiary)
                } else {
                    ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                        Rectangle()
                            .fill(slice.1)
                            .frame(width: max(3, usable * CGFloat(slice.0) / CGFloat(total)))
                    }
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipShape(.capsule)
        }
    }
}

struct ScheduleEditorView: View {
    @State var rule: ScheduleRule
    let onSave: (ScheduleRule) -> Void
    @Environment(\.dismiss) private var dismiss

    private let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("名稱", text: $rule.name)
                Toggle("啟用", isOn: $rule.enabled)
                Picker("模式", selection: $rule.mode) {
                    ForEach(RecordingMode.allCases) { Text($0.title).tag($0) }
                }
                Section("星期") {
                    HStack {
                        ForEach(1...7, id: \.self) { day in
                            let on = rule.weekdays.contains(day)
                            Button(weekdayNames[day - 1]) {
                                Haptics.selection()
                                if on { rule.weekdays.remove(day) } else { rule.weekdays.insert(day) }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: .circle)
                            .foregroundStyle(on ? .white : .primary)
                        }
                    }
                }
                Section {
                    DatePicker("開始", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("結束", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                } footer: {
                    if rule.crossesMidnight { Text("結束時間比開始早，會錄到隔天。") }
                }
            }
            .navigationTitle("排程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { Haptics.success(); onSave(rule); dismiss() }.disabled(rule.weekdays.isEmpty)
                }
            }
        }
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<ScheduleRule, Int>) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(rule[keyPath: keyPath] * 60))
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            rule[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
    }
}

struct ShortcutsGuideView: View {
    var body: some View {
        List {
            Section("全自動開始") {
                step(1, "打開「捷徑」App → 下方「自動化」→ 右上「＋」")
                step(2, "選「特定時間」，設定開始時間（例如 09:00）與星期")
                step(3, "選「立即執行」（不要選「執行前確認」）")
                step(4, "動作搜尋「Recap」，選「開始全天錄音」或「開始課堂模式」")
                step(5, "可以在「錄幾分鐘」填時長；不填的話，若在 App 的排程時段內，會錄到時段結束")
            }
            Section("自動停止") {
                Text("在 App 的排程裡設好結束時間，或在捷徑填「錄幾分鐘」，時間到 App 會自己停。也可以另外做一個「特定時間 → 停止錄音」的自動化。")
            }
            Section("其他用法") {
                Text("・設定 → 動作按鈕 → 捷徑 → 選「開始錄音」，按一下就開始。")
                Text("・跟 Siri 說「Recap 開始錄音」、「Recap 課堂模式」。")
                Text("・「今日 Recap」可以在捷徑裡讓 Siri 唸出今天的重點。")
            }
            Section {
                Text("為什麼要這樣做？iOS 不讓 App 在背景自己打開麥克風。捷徑的「開始錄音」用的是系統的 AudioRecordingIntent，是 Apple 允許從背景開始錄音的正式方式，錄音時會在動態島顯示。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("捷徑自動化")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.headline).foregroundStyle(.tint).frame(width: 20)
            Text(text)
        }
    }
}

/// 自訂詞彙：人名、公司、課程術語，辨識時會優先認這些詞。
struct VocabularyView: View {
    @Environment(AppSettings.self) private var settings
    @State private var newWord = ""

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                HStack {
                    TextField("例如：王小明、opportunity cost", text: $newWord)
                        .onSubmit(add)
                    Button("加入", action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("把常出現的人名、公司、產品、課程術語加進來，語音辨識會優先認這些詞，AI 校正時也會照這個寫法。可以一次貼上多個，用逗號或換行分開。")
            }
            Section {
                ForEach(settings.vocabulary, id: \.self) { Text($0) }
                    .onDelete { settings.vocabulary.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("自訂詞彙")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        let words = newWord.components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !settings.vocabulary.contains($0) }
        guard !words.isEmpty else { return }
        Haptics.success()
        settings.vocabulary.append(contentsOf: words)
        newWord = ""
    }
}

/// 選擇 AI：Apple Intelligence 或 Gemini（API Key、模型）。
struct AIProviderView: View {
    @Environment(AppSettings.self) private var settings
    @State private var keyDraft = ""
    @State private var models: [GeminiModelInfo] = []
    @State private var loading = false
    @State private var message: String?
    @State private var customModel = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("使用", selection: $settings.aiProvider) {
                    ForEach(AIConfig.Provider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Apple Intelligence 完全離線、免費，但一次只能看一小段。Gemini 需要網路和 API Key，能一次讀完整天的逐字稿，摘要和追問更完整。選 Muse 的話，App 不自己整理筆記和摘要，逐字稿同步給 Muse，由 Muse 整理後寫回來。")
            }

            if settings.aiProvider == .muse {
                Section {
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        LabeledContent("Muse 同步", value: settings.canSync ? "已連線" : "未連線")
                    }
                } footer: {
                    Text("Apple Intelligence 只用在小事：確認是不是課表上的那堂課、檢查辨識品質、回答追問。")
                }
            }

            if settings.aiProvider == .gemini {
                Section {
                    SecureField("貼上 API Key", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("儲存並測試") { Task { await saveAndTest() } }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                    if !settings.geminiAPIKey.isEmpty {
                        Button("移除 API Key", role: .destructive) {
                            settings.geminiAPIKey = ""
                            keyDraft = ""
                            models = []
                            message = nil
                            Haptics.warning()
                        }
                    }
                    if loading { ProgressView() }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("到 Google AI Studio（aistudio.google.com）登入後按「Get API key」免費建立。Key 只存在這支手機的鑰匙圈。")
                }

                Section {
                    ForEach(GeminiClient.recommended) { item in
                        modelRow(id: item.id, title: item.title, detail: item.detail)
                    }
                } header: {
                    Text("推薦模型")
                } footer: {
                    Text("「latest」會自動使用 Google 最新的同級模型，不用擔心舊型號下架。")
                }

                if !models.isEmpty {
                    Section("這把 Key 可用的全部模型") {
                        ForEach(models) { model in
                            modelRow(id: model.id, title: model.displayName, detail: model.id + (model.inputLimit > 0 ? "・上下文 \(model.inputLimit / 1000)K" : ""))
                        }
                    }
                } else if !settings.geminiAPIKey.isEmpty {
                    Section {
                        Button("取得可用模型清單") { Task { await loadModels() } }.disabled(loading)
                    }
                }

                Section {
                    TextField("自訂模型代號，例如 gemini-2.5-flash", text: $customModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            let id = customModel.trimmingCharacters(in: .whitespaces)
                            if !id.isEmpty { settings.geminiModel = id; Haptics.selection() }
                        }
                } footer: {
                    Text("目前使用：\(settings.geminiModel)")
                }
            }
        }
        .navigationTitle("AI 模型")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: settings.aiProvider)
        .onAppear { keyDraft = settings.geminiAPIKey }
    }

    private func modelRow(id: String, title: String, detail: String) -> some View {
        Button {
            settings.geminiModel = id
            Haptics.selection()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settings.geminiModel == id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func saveAndTest() async {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        loading = true
        defer { loading = false }
        do {
            // 先用模型清單確認 Key 有效（不受模型忙碌影響），有效就先存起來
            _ = try await GeminiClient.listModels(apiKey: key)
            settings.geminiAPIKey = key
            await loadModels()
            do {
                let reply = try await GeminiClient.generate(system: "只回答「OK」。", prompt: "測試", model: settings.geminiModel, apiKey: key)
                message = "連線成功（回覆：\(reply.prefix(20))）"
            } catch GeminiError.busy {
                message = "Key 有效，已儲存。Google 的模型現在太忙，稍後整理時會自動重試或改用備用模型。"
            } catch GeminiError.quota {
                message = "Key 有效，已儲存。這個模型的免費額度暫時用完，整理時會自動改用備用模型。"
            }
            Haptics.success()
        } catch {
            message = "測試失敗：\(error.localizedDescription)"
            Haptics.error()
        }
    }

    private func loadModels() async {
        let key = settings.geminiAPIKey
        guard !key.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            models = try await GeminiClient.listModels(apiKey: key)
        } catch {
            message = "取得模型清單失敗：\(error.localizedDescription)"
        }
    }
}

/// 學習記憶：App 從課堂筆記和 AI 校正裡學到的詞。
struct LearningMemoryView: View {
    @Environment(AppSettings.self) private var settings
    @State private var memory = LearningMemory.shared
    @State private var filter: SchoolSubject?
    @State private var newTerm = ""
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle("學習記憶", isOn: $settings.learningMemory)
            } footer: {
                Text("開啟後，App 會記住課堂筆記裡的術語，以及 AI 校正時改回來的英文單字。之後轉文字時會優先認這些詞，整理新的一堂課時也會參考同科目之前上過的課，越用越準。全部只存在這支手機。")
            }
            if settings.learningMemory {
                Section {
                    Picker("科目", selection: $filter) {
                        Text("全部").tag(SchoolSubject?.none)
                        ForEach(SchoolSubject.allCases) { Text($0.title).tag(SchoolSubject?.some($0)) }
                    }
                    HStack {
                        TextField("手動加入一個詞", text: $newTerm)
                            .textInputAutocapitalization(.never)
                            .onSubmit(add)
                        Button("加入", action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("記住的詞（\(shown.count)）") {
                    if shown.isEmpty { Text("還沒有學到的詞，上幾堂課之後就會出現。").foregroundStyle(.secondary) }
                    ForEach(shown) { term in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(term.term)
                                Spacer()
                                if let subject = term.subject { Text(subject.title).font(.caption).foregroundStyle(.secondary) }
                                Text("×\(term.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            if let note = term.note, !note.isEmpty {
                                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { memory.remove(shown[index]) }
                        Haptics.warning()
                    }
                }
                Section {
                    Button("清除全部記憶", role: .destructive) { confirmClear = true }
                }
            }
        }
        .navigationTitle("學習記憶")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("要清除所有記住的詞嗎？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { memory.clear(); Haptics.warning() }
        }
    }

    private var shown: [LearnedTerm] {
        memory.terms
            .filter { filter == nil || $0.subject == filter }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastSeen > $1.lastSeen }
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        memory.add(term, subject: filter)
        newTerm = ""
        Haptics.success()
    }
}

/// Groq Whisper：AI 判斷轉得不好、內容又複雜的段落，才送去重新辨識。
struct WhisperSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var keyDraft = ""
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("用 Whisper 補強辨識", isOn: $settings.whisperEnabled)
            } footer: {
                Text("每段錄音轉完文字後，AI（Gemini 或 Apple Intelligence）會檢查逐字稿：句子不通順、英文被寫成諧音、內容又很專業的段落，才把那一段錄音送到 Groq 的 Whisper 重新辨識。課堂錄音會切成每 2 分鐘一塊，只送最需要的幾塊。送出的錄音會上傳到 Groq 的伺服器。")
            }
            Section {
                SecureField(settings.groqAPIKey.isEmpty ? "貼上 gsk_ 開頭的 Key" : "已設定（重新貼上可更換）", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(loading ? "測試中…" : "儲存並測試") { Task { await saveAndTest() } }
                    .disabled(loading || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Groq API Key")
            } footer: {
                Text("到 console.groq.com 登入後在「API Keys」免費建立。Key 只存在這支手機的鑰匙圈。")
            }
            Section {
                Stepper("每天最多 \(settings.whisperDailyMinutes) 分鐘", value: $settings.whisperDailyMinutes, in: 10...480, step: 10)
                LabeledContent("今天已用", value: "\(Int(WhisperBudget.usedToday / 60)) 分鐘")
            } header: {
                Text("每日額度")
            } footer: {
                Text("額度用完就不再送，明天自動重算。Groq 每次最少算 10 秒；分數最高（最需要）的段落先送。")
            }
            Section("模型") {
                Picker("Whisper 模型", selection: $settings.whisperModel) {
                    ForEach(GroqWhisper.models, id: \.id) { model in
                        VStack(alignment: .leading) {
                            Text(model.title)
                            Text(model.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(model.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle("Whisper 補強")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveAndTest() async {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        loading = true
        defer { loading = false }
        do {
            try await GroqWhisper.testKey(key, model: settings.whisperModel)
            WhisperBudget.spend(1)
            settings.groqAPIKey = key
            settings.whisperEnabled = true
            keyDraft = ""
            message = "連線成功，已開啟 Whisper 補強。"
            Haptics.success()
        } catch WhisperError.quota {
            settings.groqAPIKey = key
            keyDraft = ""
            message = "Key 已儲存，但今天的 Groq 額度已經用完，明天會自動開始補強。"
        } catch {
            message = "測試失敗：\(error.localizedDescription)"
            Haptics.error()
        }
    }
}

/// 同步到自己的 Supabase，Muse 讀取後整理並寫回。
struct SyncSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var urlDraft = ""
    @State private var keyDraft = ""
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("同步給 Muse", isOn: $settings.syncEnabled)
                    .disabled(settings.syncToken.isEmpty)
            } footer: {
                Text("轉好文字後，會把最近 7 天的錄音逐字稿和課堂上傳到你自己的 Supabase，Muse 讀取後整理成筆記、摘要和 Recap 寫回來，顯示在課堂和今天的畫面。只傳文字，不傳錄音。")
            }
            Section {
                TextField("https://xxxx.supabase.co", text: $urlDraft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Publishable key（sb_publishable_… 或 anon key）", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(loading ? "連線中…" : (settings.syncToken.isEmpty ? "連線" : "重新連線")) { Task { await connect() } }
                    .disabled(loading || urlDraft.isEmpty || keyDraft.isEmpty)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Supabase 專案")
            } footer: {
                Text("網址和 publishable key 在 Supabase 專案的 Settings → API。第一次連線時，App 會自己產生一組私人 Token 綁定這個專案（只存在這支手機的鑰匙圈），之後只有這支手機能讀寫。")
            }
            Section {
                Button("立即同步") {
                    Task {
                        loading = true
                        message = await RecapSync.run()
                        loading = false
                    }
                }
                .disabled(loading || !settings.canSync)
                if let last = RecapSync.lastSync {
                    LabeledContent("上次同步", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                if let error = RecapSync.lastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Muse 同步")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            urlDraft = settings.syncServerURL
            keyDraft = settings.syncAPIKey
        }
    }

    private func connect() async {
        loading = true
        defer { loading = false }
        do {
            try await RecapSync.connect(url: urlDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                        apiKey: keyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            message = "連線成功，正在第一次同步…"
            Haptics.success()
            message = await RecapSync.run()
        } catch {
            message = "連線失敗：\(error.localizedDescription)"
            Haptics.error()
        }
    }
}
