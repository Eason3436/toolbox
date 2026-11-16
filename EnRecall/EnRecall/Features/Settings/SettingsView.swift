import SwiftUI
import SwiftData
import UIKit

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
            ConnectorSection()
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

            Section("關於") {
                NavigationLink {
                    ChangelogView()
                } label: {
                    LabeledContent("更新日誌") {
                        Text(AppConfig.appVersion)
                            .font(.erMono)
                            .monospacedDigit()
                    }
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

// MARK: - Claude 連接器

private struct ConnectorSection: View {
    @Environment(InboxService.self) private var inbox
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.modelContext) private var context

    @State private var confirmRegenerate = false
    @State private var isWorking = false
    @State private var copied = 0
    @AppStorage(SettingsKey.shareStats) private var shareStats = true

    var body: some View {
        Section {
            if let url = inbox.connectorURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("連接器網址")
                        .font(.subheadline)
                        .foregroundStyle(Color.er.textSecondary)
                    Text(url.absoluteString)
                        .font(.erMonoSmall)
                        .foregroundStyle(Color.er.text)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)

                Button("複製連接器網址", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = url.absoluteString
                    copied += 1
                    toasts.show("已複製連接器網址", systemImage: "doc.on.doc")
                }
                .sensoryFeedback(.success, trigger: copied)

                Button {
                    Task { await importNow() }
                } label: {
                    LabeledContent("立即匯入") {
                        statusText
                    }
                }
                .disabled(inbox.status == .syncing)

                Toggle("分享學習紀錄", isOn: $shareStats)
                    .onChange(of: shareStats) { _, isOn in
                        guard isOn else { return }
                        Task { await inbox.uploadSnapshot(context: context, force: true) }
                    }

                Button("重新產生配對碼", role: .destructive) {
                    confirmRegenerate = true
                }
                .disabled(isWorking)
            } else {
                Text("後端還沒設定")
                    .foregroundStyle(Color.er.textTertiary)
            }
        } header: {
            Text("Claude 連接器")
        } footer: {
            if inbox.connectorURL != nil {
                Text("分享後，Claude 看得到最近的複習成績，可以幫忙分析、做複習講義")
            }
        }
        .confirmationDialog("重新產生配對碼？", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("重新產生", role: .destructive) {
                Task { await regenerate() }
            }
        } message: {
            Text("舊的網址會立刻失效，要到 Claude 重新設定連接器")
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch inbox.status {
        case .syncing:
            ProgressView()
        case .offline:
            Text("無法連線")
                .foregroundStyle(Color.er.danger)
        case .connected:
            if let last = inbox.lastCheck {
                Text(last, format: .relative(presentation: .named))
                    .foregroundStyle(Color.er.textTertiary)
            }
        case .idle, .notConfigured:
            EmptyView()
        }
    }

    private func importNow() async {
        guard let result = await inbox.sync(context: context, force: true) else { return }
        if let message = result.toastMessage {
            toasts.show(message, systemImage: "square.and.arrow.down")
        } else if inbox.status == .connected {
            toasts.show("收件匣是空的", systemImage: "tray")
        }
    }

    private func regenerate() async {
        isWorking = true
        defer { isWorking = false }
        if await inbox.regenerate() {
            toasts.show("已換新的配對碼，記得到 Claude 更新網址", systemImage: "key")
        } else {
            toasts.show("需要網路才能重新產生", systemImage: "wifi.slash")
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
