import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts

    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system
    @AppStorage(SettingsKey.dailyNewLimit) private var dailyNewLimit = AppDefaults.dailyNewLimit
    @AppStorage(SettingsKey.reminderEnabled) private var reminderEnabled = false
    @AppStorage(SettingsKey.reminderSeconds) private var reminderSeconds = AppDefaults.reminderSeconds

    @State private var confirmReset = false

    /// 提醒時間：存成一天中的秒數，畫面上用 DatePicker
    private var reminderTime: Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(reminderSeconds))
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            reminderSeconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60
        }
    }

    var body: some View {
        Form {
            Section("Claude 連接器") {
                if AppConfig.isBackendConfigured {
                    // 配對碼與網址在 M5 接上
                    LabeledContent("連接器網址") {
                        Text("—").foregroundStyle(Color.er.textTertiary)
                    }
                    LabeledContent("待匯入") {
                        Text("0").monospacedDigit()
                    }
                    Button("重新產生配對碼", role: .destructive) {}
                        .disabled(true)
                } else {
                    Text("後端還沒設定")
                        .foregroundStyle(Color.er.textTertiary)
                }
            }
            .listRowBackground(Color.er.surface)

            Section("外觀") {
                Picker("主題", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            .listRowBackground(Color.er.surface)

            Section("學習") {
                Stepper(value: $dailyNewLimit, in: 0...200, step: 5) {
                    LabeledContent("每日新卡上限") {
                        Text(dailyNewLimit, format: .number).monospacedDigit()
                    }
                }
                Toggle("每日提醒", isOn: $reminderEnabled)
                if reminderEnabled {
                    DatePicker("提醒時間", selection: reminderTime, displayedComponents: .hourAndMinute)
                }
            }
            .listRowBackground(Color.er.surface)

            Section {
                Button("重置所有進度", role: .destructive) {
                    confirmReset = true
                }
            } header: {
                Text("資料")
            } footer: {
                Text("EnRecall iOS \(AppConfig.appVersion)")
                    .font(.erMonoSmall)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
            .listRowBackground(Color.er.surface)
        }
        .scrollContentBackground(.hidden)
        .erPageBackground()
        .navigationTitle("設定")
        .animation(.spring(duration: 0.3), value: reminderEnabled)
        .confirmationDialog("重置所有進度？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("重置", role: .destructive, action: resetProgress)
        } message: {
            Text("所有卡片回到新卡，複習紀錄全部清掉。牌組和單字會保留")
        }
    }

    private func resetProgress() {
        do {
            let cards = try context.fetch(FetchDescriptor<Card>())
            for card in cards {
                card.state = .new
                card.stability = 0
                card.difficulty = 0
                card.due = Date()
                card.lastReview = nil
                card.reps = 0
                card.lapses = 0
            }
            try context.delete(model: ReviewLog.self)
            try context.save()
            toasts.show("已重置所有進度", systemImage: "arrow.counterclockwise")
        } catch {
            toasts.show("重置失敗", systemImage: "exclamationmark.triangle")
        }
    }
}

#Preview("淺色") {
    NavigationStack {
        SettingsView()
    }
    .previewEnvironment()
}

#Preview("深色") {
    NavigationStack {
        SettingsView()
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
