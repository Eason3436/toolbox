import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RecapStore.self) private var store
    @Environment(ProcessingQueue.self) private var queue
    @State private var locales: [Locale] = []
    @State private var installed: Set<String> = []
    @State private var editing: ScheduleRule?
    @State private var cleanupMessage: String?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
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
                } header: {
                    Text("排程錄音")
                } footer: {
                    Text("iOS 不允許 App 自己在背景定時打開麥克風。排程時間到了會發通知，點一下就開始；錄音中到了結束時間會自動停止。想完全自動，請照下面「捷徑自動化」設定。")
                }

                Section {
                    NavigationLink("設定捷徑自動化（全自動排程）") { ShortcutsGuideView() }
                } footer: {
                    Text("用「捷徑」的「特定時間」自動化執行「開始全天錄音」，就能在背景直接開始，不用點通知。也可以把「開始錄音」設到動作按鈕。")
                }

                Section {
                    Picker("辨識語言", selection: $settings.transcriptionLocale) {
                        if locales.isEmpty { Text(settings.transcriptionLocale).tag(settings.transcriptionLocale) }
                        ForEach(locales, id: \.identifier) { locale in
                            Text(SpeechSupport.displayName(locale) + (installed.contains(locale.identifier) ? " ✓" : ""))
                                .tag(locale.identifier)
                        }
                    }
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
                    Toggle("AI 校正逐字稿錯字", isOn: $settings.aiCorrection)
                    Toggle("中英夾雜辨識", isOn: $settings.mixedLanguage)
                    Toggle("高中上課用語與專有名詞", isOn: $settings.highSchoolMode)
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
                    Toggle("安靜的段落不轉文字", isOn: $settings.skipSilence)
                    Toggle("轉好文字後刪除音檔", isOn: $settings.deleteAudioAfterTranscribe)
                } header: {
                    Text("全天錄音")
                } footer: {
                    Text("中英夾雜辨識：每段錄音會用中文和英文模型各聽一次，再由 AI 合併，英文單字和術語不會變成中文諧音。轉文字時間約多一倍（在背景或充電時做）。課堂模式會在下課後用錄音重新辨識一次。\n高中上課用語：加入段考、學測、講義、第幾頁等上課常講的詞，課堂模式再依科目加入那科的專有名詞。\n自動省電：連續 3 分鐘沒有人在近處說話（只有遠處的背景人聲或安靜）就關掉人聲加強、改用較低位元率；一偵測到有人靠近說話或老師開始講課，就馬上恢復。下次開始錄音時生效。\n清單是用 SpeechTranscriber.supportedLocales 實際查到的，打勾代表語音模型已在手機上。第一次用某個語言會自動下載模型（需要網路一次），之後完全離線。")
                }

                Section("AI 摘要與追問") {
                    NavigationLink {
                        AIProviderView()
                    } label: {
                        LabeledContent("AI 模型", value: settings.aiProvider == .gemini ? (settings.geminiAPIKey.isEmpty ? "Gemini（未設定 Key）" : settings.geminiModel) : "Apple Intelligence")
                    }
                    Label(ModelReadiness.current.message, systemImage: ModelReadiness.current == .available ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(ModelReadiness.current == .available ? .green : .orange)
                    Text(settings.aiProvider == .gemini ? "用 Gemini 時，逐字稿會傳到 Google 伺服器處理，上下文很大，整天的內容可以一次整理、追問也能看完整份紀錄。沒網路時會改用裝置上的模型。" : "摘要用裝置上的模型，一次只能看約 4096 tokens，所以每段先各自摘要，再合併成今日 Recap。背景只錄音與轉文字，摘要在打開 App 或充電時進行。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("現在整理全部") { queue.kick(summaries: true) }
                        .disabled(queue.isRunning)
                }

                Section {
                    LabeledContent("錄音檔佔用", value: ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file))
                    Picker("錄音檔保留", selection: $settings.audioRetentionDays) {
                        Text("1 天").tag(1)
                        Text("3 天").tag(3)
                        Text("7 天").tag(7)
                        Text("14 天").tag(14)
                        Text("30 天").tag(30)
                        Text("永久保留").tag(0)
                    }
                    Button("現在清理過期錄音檔") {
                        let n = store.purgeAudio(olderThan: settings.audioRetentionDays)
                        cleanupMessage = n == 0 ? "沒有過期的錄音檔" : "刪除了 \(n) 個錄音檔（文字稿和摘要都還在）"
                    }
                    .disabled(settings.audioRetentionDays == 0)
                    if let cleanupMessage { Text(cleanupMessage).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("儲存空間")
                } footer: {
                    Text("超過保留天數的錄音檔（全天錄音和課堂）會自動刪除，只留下文字稿、翻譯和摘要，追問也照樣能用。還沒轉成文字的錄音不會被刪。")
                }

                Section {
                    Text("錄音時狀態列會亮橘色麥克風燈號，這是系統規定，App 無法隱藏。整天收音很耗電，放口袋收音也會比較差，建議放桌上或接電源。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .sensoryFeedback(.selection, trigger: settings.segmentMinutes)
            .sensoryFeedback(.selection, trigger: settings.audioRetentionDays)
            .sensoryFeedback(.selection, trigger: settings.transcriptionLocale)
            .sensoryFeedback(.selection, trigger: settings.skipSilence)
            .sensoryFeedback(.selection, trigger: settings.autoStartInSchedule)
            .sensoryFeedback(.selection, trigger: settings.scheduleNotifications)
            .sensoryFeedback(.selection, trigger: settings.deleteAudioAfterTranscribe)
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
            .task {
                locales = await SpeechSupport.supportedLocales().sorted { $0.identifier < $1.identifier }
                installed = Set(await SpeechSupport.installedLocales().map(\.identifier))
            }
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
                Text("Apple Intelligence 完全離線、免費，但一次只能看一小段。Gemini 需要網路和 API Key，能一次讀完整天的逐字稿，摘要和追問更完整。")
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
            let reply = try await GeminiClient.generate(system: "只回答「OK」。", prompt: "測試", model: settings.geminiModel, apiKey: key)
            settings.geminiAPIKey = key
            message = "連線成功（\(settings.geminiModel) 回覆：\(reply.prefix(20))）"
            Haptics.success()
            await loadModels()
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
