import SwiftUI

@main
struct DrivePlayerApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .preferredColorScheme(.dark)
                .onOpenURL { services.auth.handle($0) }
                .task { await services.auth.restore() }
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
