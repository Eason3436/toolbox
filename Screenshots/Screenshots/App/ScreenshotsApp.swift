import CoreSpotlight
import SwiftUI
import os

/// 全 App 共用的 Logger。
let appLog = Logger(subsystem: "com.eason3436.screenshots", category: "app")

@main
struct ScreenshotsApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let services = AppServices.shared

    init() {
        BackgroundAnalysis.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services.library)
                .environment(services.queueStatus)
                .environment(services.router)
                .modelContainer(services.container)
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // 從 Spotlight 點進來
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        services.router.openScreenshot(id)
                    }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: services.didBecomeActive()
            case .background: services.didEnterBackground()
            default: break
            }
        }
    }
}
