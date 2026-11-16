import SwiftUI
import SwiftData

@main
struct EnRecallApp: App {
    @State private var store = StoreModel()
    @State private var toasts = ToastCenter()
    @State private var inbox = InboxService()
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(toasts)
                .environment(inbox)
                .preferredColorScheme(appearance.colorScheme)
                .tint(Color.er.primary)
        }
        // 資料庫在 App 自己的 Application Support：SideStore 續簽、覆蓋安裝都不會清掉
        .modelContainer(for: [Deck.self, Card.self, ReviewLog.self])
    }
}
