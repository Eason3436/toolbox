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
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            Tab("首頁", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    HomeView().appDestinations()
                }
            }
            Tab("牌組", systemImage: "rectangle.stack", value: AppTab.decks) {
                NavigationStack {
                    DecksView().appDestinations()
                }
            }
            Tab("紀錄", systemImage: "chart.bar", value: AppTab.stats) {
                NavigationStack {
                    StatsView()
                }
            }
            Tab("字典", systemImage: "book.closed", value: AppTab.dictionary) {
                NavigationStack {
                    DictionaryView()
                }
            }
            Tab("設定", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .top) {
            ToastHost()
        }
        .task {
            // 商店清單先在背景抓，首頁才知道有沒有新版
            await store.load()
            if await store.upgradeOutdated(context: context) > 0 {
                toasts.show("單字已補上搭配與近義字", systemImage: "text.book.closed")
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // 每次回到前景都領一次 Claude 送來的字
            guard phase == .active else { return }
            Task { await importFromClaude() }
        }
    }
}

extension RootView {
    private func importFromClaude() async {
        guard let result = await inbox.sync(context: context), let message = result.toastMessage else { return }
        toasts.show(message, systemImage: "square.and.arrow.down")
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
