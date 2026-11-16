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
        }
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
