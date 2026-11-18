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
        // 資料庫在 App 自己的 Application Support：SideStore 續簽、覆蓋安裝都不會清掉
        .modelContainer(for: [ViewedAsset.self, CleanStats.self])
    }
}
