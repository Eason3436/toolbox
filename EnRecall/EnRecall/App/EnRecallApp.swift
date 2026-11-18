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
        // 資料庫固定在 App 自己的 Application Support（AppDatabase.swift），不用 SwiftData 預設的 default.store
        .modelContainer(AppDatabase.container)
    }
}
