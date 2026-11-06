import SwiftData
import SwiftUI

/// 借放在 Recap 裡的 HealthMi（小米運動健康 → Apple 健康）。
/// 原專案：https://github.com/ShawnDiego/HealthMi（Apache-2.0，授權見 LICENSE.txt、NOTICE.txt）。
/// 這裡只換掉原本的 App 進入點：資料庫與狀態由這個 Host 持有，從設定頁打開。
@MainActor
enum HealthMiHost {
    static let model = HMAppModel()

    static let container: ModelContainer? = {
        let schema = Schema([SyncState.self, StressRecord.self, SyncLogEntry.self])
        let url = URL.applicationSupportDirectory.appending(path: "HealthMi.store")
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration("HealthMi", schema: schema, url: url)
        return try? ModelContainer(for: schema, migrationPlan: MigrationPlan.self, configurations: [configuration])
    }()

    /// 有登入過小米帳號才排背景同步，沒用到這個功能就完全不打擾。
    static var isSetUp: Bool { CredentialStore.load() != nil }

    /// App 啟動時呼叫（背景工作一定要在啟動完成前註冊）。
    static func registerBackground() {
        BackgroundSync.register {
            guard let container else { return }
            model.bootstrap()
            await model.syncAll(modelContext: container.mainContext, isBackground: true)
        }
        if isSetUp { BackgroundSync.schedule() }
    }
}

/// 設定頁打開的小米健康同步畫面（以全頁面卡片呈現，往下滑關閉）。
struct HealthMiScreen: View {
    @State private var booted = false

    var body: some View {
        Group {
            if let container = HealthMiHost.container {
                HMRootView()
                    .environment(HealthMiHost.model)
                    .modelContainer(container)
            } else {
                ContentUnavailableView("無法開啟", systemImage: "exclamationmark.triangle",
                                       description: Text("小米健康同步的資料庫建立失敗。"))
            }
        }
        .task {
            guard !booted else { return }
            booted = true
            HealthMiHost.model.bootstrap()
            await NotificationManager.requestAuthorization()
            BackgroundSync.schedule()
        }
    }
}
