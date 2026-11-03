import SwiftUI

/// 依照片權限與首次設定決定顯示哪個畫面。
struct RootView: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("importRange") private var importRange: ImportRange = .all
    @AppStorage("didChooseImportRange") private var didChooseImportRange = false

    var body: some View {
        Group {
            switch library.access {
            case .notDetermined, .denied:
                PermissionView()
            case .limited, .full:
                if didChooseImportRange {
                    MainTabView()
                } else {
                    ImportRangeView { range in
                        importRange = range
                        didChooseImportRange = true
                    }
                }
            }
        }
        .task(id: reloadKey) { reloadIfReady() }
        .onChange(of: scenePhase) { _, phase in
            // 回到 App 時重新讀取，讓新截圖出現、刪除的消失（階段 2 會改成增量同步）。
            guard phase == .active else { return }
            library.refreshAccess()
            reloadIfReady()
        }
    }

    private var reloadKey: String {
        "\(library.access)-\(importRange.rawValue)-\(didChooseImportRange)"
    }

    private func reloadIfReady() {
        guard didChooseImportRange else { return }
        library.reload(range: importRange)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("截圖", systemImage: "photo.on.rectangle.angled") {
                HomeView()
            }
            Tab("收藏集", systemImage: "square.grid.2x2") {
                ComingSoonView(title: "收藏集", symbol: "square.grid.2x2", message: "之後可以自訂收藏集，並依分類自動整理截圖。")
            }
            Tab("問答", systemImage: "sparkles") {
                ComingSoonView(title: "問答", symbol: "sparkles", message: "之後可以用一句話問你的截圖，例如「上次截的那家拉麵店叫什麼？」")
            }
            Tab("設定", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

struct ComingSoonView: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: symbol, description: Text(message))
                .navigationTitle(title)
        }
    }
}
