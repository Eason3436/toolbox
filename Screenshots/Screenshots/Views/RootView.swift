import SwiftUI

/// 依照片權限與首次設定決定顯示哪個畫面。
struct RootView: View {
    @Environment(PhotoSyncService.self) private var library
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
                        AppServices.shared.didBecomeActive()
                    }
                }
            }
        }
        .onChange(of: library.access) { _, access in
            if access == .full || access == .limited, didChooseImportRange {
                AppServices.shared.didBecomeActive()
            }
        }
        .onChange(of: importRange) { _, _ in
            library.resync()
        }
        .alert("發生錯誤", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("好") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}

struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("截圖", systemImage: "photo.on.rectangle.angled", value: AppRouter.TabID.home) {
                HomeView()
            }
            Tab("收藏集", systemImage: "square.grid.2x2", value: AppRouter.TabID.collections) {
                CollectionsView()
            }
            Tab("問答", systemImage: "sparkles", value: AppRouter.TabID.ask) {
                AskView()
            }
            Tab("設定", systemImage: "gearshape", value: AppRouter.TabID.settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
