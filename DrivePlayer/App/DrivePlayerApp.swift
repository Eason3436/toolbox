import Core
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
                    HomeView()
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
        .overlay(alignment: .top) {
            StatusBanner()
                .animation(.snappy, value: services.network.isOnline)
                .animation(.snappy, value: services.auth.sessionExpired)
        }
        .confirmationDialog(
            "要從哪裡開始？",
            isPresented: Binding(get: { services.pendingResume != nil }, set: { if !$0 { services.pendingResume = nil } }),
            titleVisibility: .visible,
            presenting: services.pendingResume
        ) { item in
            if let t = services.playback.resumePosition(for: item.fileId) {
                Button("從 \(Timecode.string(t)) 繼續") { services.play(item, resumeDecided: true) }
            }
            Button("從頭播放") { services.play(item, fromBeginning: true, resumeDecided: true) }
        }
        .alert(
            "正在使用行動網路",
            isPresented: Binding(get: { services.pendingCellular != nil }, set: { if !$0 { services.pendingCellular = nil } }),
            presenting: services.pendingCellular
        ) { pending in
            Button("播放") { services.approveCellular(pending) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("4K 影片一小時可能用掉 20 GB 以上的流量。這次打開 App 期間不會再問。")
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
