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
                    Toggle("安靜的段落不轉文字", isOn: $settings.skipSilence)
                    Toggle("轉好文字後刪除音檔", isOn: $settings.deleteAudioAfterTranscribe)
                } header: {
                    Text("全天錄音")
                } footer: {
                    Text("清單是用 SpeechTranscriber.supportedLocales 實際查到的，打勾代表語音模型已在手機上。第一次用某個語言會自動下載模型（需要網路一次），之後完全離線。")
                }

                Section("Apple Intelligence") {
                    Label(queue.readiness.message, systemImage: queue.readiness == .available ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(queue.readiness == .available ? .green : .orange)
                    Text("摘要用裝置上的模型，一次只能看約 4096 tokens，所以每段先各自摘要，再合併成今日 Recap。背景只錄音與轉文字，摘要在打開 App 或充電時進行。")
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
                    Button("儲存") { onSave(rule); dismiss() }.disabled(rule.weekdays.isEmpty)
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
