import SwiftUI
import SwiftData

@main
struct SweepApp: App {
    @State private var queue = DeletionQueue()
    @State private var island = IslandModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(queue)
                .environment(island)
        }
        // 資料庫固定在 App 自己的 Application Support（AppDatabase.swift），不用 SwiftData 預設的 default.store
        .modelContainer(AppDatabase.container)
    }
}
