import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts
    @Environment(StoreModel.self) private var store

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
                Picker("深淺色", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                PaletteGrid()
            }
            .listRowBackground(Color.er.surface)

            Section {
                LabeledContent("每日新卡上限") {
                    RollingCounter(value: $dailyNewLimit, in: 0...200)
                        .accessibilityLabel("每日新卡上限")
                }
                Toggle("每日提醒", isOn: $reminderEnabled)
                if reminderEnabled {
                    DatePicker("提醒時間", selection: reminderTime, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("學習")
            } footer: {
                if reminderEnabled && LiveContainerBridge.isInside {
                    Text("在 LiveContainer 裡要打開這個 App 設定的「修復本地通知」，提醒才會出現")
                }
            }
            .listRowBackground(Color.er.surface)

            SpeechSettingsSection()

            Section {
                StorePasswordField()
            } header: {
                Text("單字商店")
            } footer: {
                Text(store.phase == .needsPassword ? "下載、更新單字包要用，只要輸入一次" : "已經輸入過了。換密碼時再輸入一次")
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
        .onChange(of: reminderEnabled) { _, enabled in
            guard enabled else {
                Task { await ReminderScheduler.reschedule(context: context) }
                return
            }
            Task {
                if await ReminderScheduler.requestPermission() {
                    await ReminderScheduler.reschedule(context: context)
                } else {
                    reminderEnabled = false
                    toasts.show("通知被關掉了，到系統設定打開", systemImage: "bell.slash")
                }
            }
        }
        .onChange(of: reminderSeconds) {
            Task { await ReminderScheduler.reschedule(context: context) }
        }
        .onChange(of: dailyNewLimit) {
            Task { await ReminderScheduler.reschedule(context: context) }
            HomeWidgetPublisher.publish(context: context)
        }
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
            Task { await ReminderScheduler.reschedule(context: context) }
            HomeWidgetPublisher.publish(context: context)
        } catch {
            toasts.show("重置失敗", systemImage: "exclamationmark.triangle")
        }
    }
}

// MARK: - 配色

/// 配色主題：一格一個色票，點了整個 App 馬上換。一排 5 個、兩排共 10 個
private struct PaletteGrid: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配色")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(AppPalette.allCases) { palette in
                    Swatch(palette: palette, isSelected: palette == Color.er.palette) {
                        withAnimation(.easeOut(duration: 0.2)) { Color.er.use(palette) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: Color.er.palette)
    }
}

/// 一個配色：上半是背景色、下半是強調色，中間的「Aa」是文字色，看得出這組配色實際的樣子。
/// 顏色從 Assets 讀，跟著目前的深淺色：淺色模式看到淺色版、深色模式看到深色版
private struct Swatch: View {
    let palette: AppPalette
    let isSelected: Bool
    let select: () -> Void

    private let size: CGFloat = 46

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                ZStack {
                    VStack(spacing: 0) {
                        palette.color("ERBackground")
                        palette.color("ERPrimary")
                    }
                    .clipShape(Circle())
                    // 淺色背景在白底上也看得到邊界
                    .overlay(Circle().strokeBorder(Color.er.outline, lineWidth: 1))

                    Text(verbatim: "Aa")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.color("ERText"))
                }
                .frame(width: size, height: size)
                // 選取：外面一圈粗框，右下角一個勾
                .padding(4)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.er.text, lineWidth: 2.5)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(palette.color("ERText"))
                            .frame(width: 18, height: 18)
                            .background(palette.color("ERSurface"), in: Circle())
                            .overlay(Circle().strokeBorder(Color.er.text, lineWidth: 1.5))
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Text(palette.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.er.text : Color.er.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
