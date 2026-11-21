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
        .modelContainer(AppDatabase.container)
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
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var player = services.player
        TabView {
            Tab("首頁", systemImage: "house.fill") {
                NavigationStack {
                    LibraryListView()
                }
            }
            Tab("媒體庫", systemImage: "folder.fill") {
                NavigationStack {
                    LibrarySettingsView()
                }
            }
            Tab("設定", systemImage: "gearshape.fill") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .alert(
            "無法播放",
            isPresented: Binding(
                get: { player.errorMessage != nil && !player.isPresented },
                set: { if !$0 { player.errorMessage = nil } }
            )
        ) {
            Button("好") {}
        } message: {
            Text(player.errorMessage ?? "")
        }
    }
}
