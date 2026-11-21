import SwiftUI

@main
struct DrivePlayerApp: App {
    @State private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .preferredColorScheme(.dark)
                .onOpenURL { services.auth.handle($0) }
                .task { await services.auth.restore() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: services.didBecomeActive()
            case .background: services.didEnterBackground()
            default: break
            }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("首頁", systemImage: "house.fill") {
                NavigationStack {
                    ContentUnavailableView("尚未加入媒體庫", systemImage: "film.stack", description: Text("到「設定」登入 Google 並選擇資料夾"))
                        .navigationTitle("DrivePlayer")
                }
            }
            Tab("設定", systemImage: "gearshape.fill") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }
}
