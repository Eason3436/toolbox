import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case home
    case decks
    case stats
    case dictionary
    case settings
}

struct RootView: View {
    @State private var tab: AppTab = .home
    @Environment(StoreModel.self) private var store
    @Environment(InboxService.self) private var inbox
    @Environment(ToastCenter.self) private var toasts
    @Environment(ChatSession.self) private var assistant
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            Tab(value: AppTab.home) {
                NavigationStack {
                    HomeView().appDestinations()
                }
            } label: {
                TabIcon(title: "首頁", systemImage: "house")
            }
            Tab(value: AppTab.decks) {
                NavigationStack {
                    DecksView().appDestinations()
                }
            } label: {
                TabIcon(title: "牌組", systemImage: "rectangle.stack")
            }
            Tab(value: AppTab.stats) {
                NavigationStack {
                    StatsView()
                }
            } label: {
                TabIcon(title: "紀錄", systemImage: "chart.bar")
            }
            Tab(value: AppTab.dictionary) {
                NavigationStack {
                    DictionaryView()
                }
            } label: {
                TabIcon(title: "字典", systemImage: "book.closed")
            }
            Tab(value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            } label: {
                TabIcon(title: "設定", systemImage: "gearshape")
            }
        }
        // 分頁列一直保持完整大小，捲動時不縮小
        .tabBarMinimizeBehavior(.never)
        .tint(Color.er.primary)
        // 全部捲動區用柔和的邊緣（系統依列的高度決定範圍，內容本身有留邊距，不會蓋到字）
        .scrollEdgeEffectStyle(.soft, for: .all)
        .overlay(alignment: .top) {
            ToastHost()
        }
        .task {
            enableNewCardsAllOnce()
            // 商店清單先在背景抓，首頁才知道有沒有新版
            await store.load()
            if await store.upgradeOutdated(context: context) > 0 {
                toasts.show("單字包已補上新內容", systemImage: "text.book.closed")
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                // 離開超過 30 分鐘：助理換成新的對話
                assistant.willEnterForeground()
                // 每次回到前景都領一次 Claude 送來的字，順便更新學習紀錄
                Task {
                    await importFromClaude()
                    await inbox.uploadSnapshot(context: context)
                    await refreshReminders()
                }
            case .background:
                assistant.didEnterBackground()
                Task {
                    await refreshReminders()
                    await inbox.uploadSnapshot(context: context, force: true)
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .studyProgressSaved)) { _ in
            // 複習完關掉：讓 Claude 馬上看得到這次的成績
            Task {
                await refreshReminders()
                await inbox.uploadSnapshot(context: context, force: true)
            }
        }
    }
}

extension RootView {
    /// 通知和桌面小工具：照現在還有多少要背重排（App 在背景跑不了，每次用完都更新）
    private func refreshReminders() async {
        HomeWidgetPublisher.publish(context: context)
        await ReminderScheduler.reschedule(context: context)
    }

    /// 0.16.2：自己加的牌組（雜誌、課本）改成新卡一次出完。只在第一次打開新版時做一次，之後照使用者自己的設定
    private func enableNewCardsAllOnce() {
        let key = "didEnableNewCardsAll"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let decks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        for deck in decks where deck.kind == .custom {
            deck.newCardsAll = true
        }
        try? context.save()
    }

    private func importFromClaude() async {
        guard let result = await inbox.sync(context: context), let message = result.toastMessage else { return }
        toasts.show(message, systemImage: "square.and.arrow.down")
    }
}

/// 分頁列只放圖示（VoiceOver 還是唸名稱）
private struct TabIcon: View {
    let title: String
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .accessibilityLabel(title)
    }
}

#Preview("淺色") {
    RootView()
        .previewEnvironment()
}

#Preview("深色") {
    RootView()
        .previewEnvironment()
        .preferredColorScheme(.dark)
}
